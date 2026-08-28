require "sinatra"
require "json"
require "time"

MAX_SAFE_INTEGER = 9_007_199_254_740_991

TIMESTAMP_RE =
  /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})\z/

def invalid_input!
  halt 400,
       { "Content-Type" => "application/json" },
       JSON.generate("error" => "INVALID_INPUT")
end

def valid_version?(value)
  return false unless value.is_a?(String)
  return false unless value.match?(/\A[1-9][0-9]*\z/)

  n = value.to_i
  n >= 1 && n <= MAX_SAFE_INTEGER
end

def parse_timestamp(value)
  return nil unless value.is_a?(String)
  return nil unless value.match?(TIMESTAMP_RE)

  Time.iso8601(value)
rescue ArgumentError
  nil
end

def finite_number?(value)
  value.is_a?(Numeric) && value.finite?
end

def safe_non_negative_integer?(value)
  value.is_a?(Integer) &&
    value >= 0 &&
    value <= MAX_SAFE_INTEGER
end

def policy_valid?(policy)
  return false unless policy.is_a?(Hash)

  return false unless policy["datasetDigest"].is_a?(String) &&
                      !policy["datasetDigest"].empty?

  return false unless policy["schemaDigest"].is_a?(String) &&
                      !policy["schemaDigest"].empty?

  return false unless safe_non_negative_integer?(policy["maxAgeSeconds"])

  return false unless finite_number?(policy["accuracyFloor"]) &&
                      policy["accuracyFloor"].between?(0.0, 1.0)

  return false unless policy["requiredSlices"].is_a?(Hash)

  return false unless finite_number?(policy["maxLatencyMs"]) &&
                      policy["maxLatencyMs"] >= 0

  return false unless safe_non_negative_integer?(policy["maxSizeBytes"])

  return false unless finite_number?(policy["minImprovement"]) &&
                      policy["minImprovement"].between?(0.0, 1.0)

  policy["requiredSlices"].all? do |name, floor|
    name.is_a?(String) &&
      finite_number?(floor) &&
      floor.between?(0.0, 1.0)
  end
end

def check_version(version, policy, as_of)
  failures = []

  unless version.is_a?(Hash)
    return ["INVALID_VERSION"]
  end

  version_id = version["version"]

  unless valid_version?(version_id)
    failures << "INVALID_VERSION"
  end

  evaluation = version["evaluation"]

  unless evaluation.is_a?(Hash)
    failures << "MISSING_EVALUATION"
    return failures.uniq.sort
  end

  # ------------------------------------------------------------
  # Timestamp / freshness
  # ------------------------------------------------------------

  created_at = parse_timestamp(evaluation["createdAt"])

  if created_at.nil?
    failures << "INVALID_TIMESTAMP"
  else
    if created_at > as_of
      failures << "FUTURE_EVALUATION"
    elsif created_at < as_of - policy["maxAgeSeconds"]
      failures << "STALE_EVALUATION"
    end
  end

  # ------------------------------------------------------------
  # Immutable lineage / evidence binding
  # ------------------------------------------------------------

  if evaluation["artifactDigest"] != version["artifactDigest"]
    failures << "ARTIFACT_MISMATCH"
  end

  if evaluation["datasetDigest"] != policy["datasetDigest"]
    failures << "DATASET_MISMATCH"
  end

  if evaluation["schemaDigest"] != policy["schemaDigest"]
    failures << "SCHEMA_MISMATCH"
  end

  # ------------------------------------------------------------
  # Aggregate metrics
  # ------------------------------------------------------------

  accuracy = evaluation["accuracy"]
  latency = evaluation["latencyMs"]
  size = evaluation["sizeBytes"]

  # Accuracy, latency and size must all be finite.
  unless finite_number?(accuracy) &&
         finite_number?(latency) &&
         finite_number?(size)
    failures << "NON_FINITE"
  else
    # Accuracy is [0,1].
    unless accuracy.between?(0.0, 1.0)
      failures << "METRIC_RANGE"
    end

    # Latency is finite and non-negative.
    unless latency >= 0
      failures << "METRIC_RANGE"
    end

    # Size is finite, non-negative and a safe integer.
    unless safe_non_negative_integer?(size)
      failures << "METRIC_RANGE"
    end
  end

  # Accuracy floor only applies when accuracy itself is valid.
  if finite_number?(accuracy) &&
     accuracy.between?(0.0, 1.0) &&
     accuracy < policy["accuracyFloor"]
    failures << "ACCURACY_FLOOR"
  end

  # Latency limit only applies when latency is valid.
  if finite_number?(latency) &&
     latency >= 0 &&
     latency <= Float::INFINITY &&
     latency > policy["maxLatencyMs"]
    failures << "LATENCY_LIMIT"
  end

  # Size limit only applies when size is a valid non-negative safe integer.
  if safe_non_negative_integer?(size) &&
     size > policy["maxSizeBytes"]
    failures << "SIZE_LIMIT"
  end

  # ------------------------------------------------------------
  # Required slices
  # ------------------------------------------------------------

  slices = evaluation["slices"]

  policy["requiredSlices"].each do |name, floor|
    unless slices.is_a?(Hash) && slices.key?(name)
      failures << "MISSING_SLICE:#{name}"
      next
    end

    value = slices[name]

    unless finite_number?(value) &&
           value.between?(0.0, 1.0)
      failures << "SLICE_RANGE:#{name}"
      next
    end

    if value < floor
      failures << "SLICE_FLOOR:#{name}"
    end
  end

  failures.uniq.sort
end

def ranking_key(version_id, version)
  evaluation = version["evaluation"]

  [
    -evaluation["accuracy"],
    evaluation["latencyMs"],
    evaluation["sizeBytes"],
    version_id.to_i
  ]
end

def public_failed_gates(failures_by_version)
  failures_by_version
    .transform_values { |codes| codes.uniq.sort }
end

def json_response(result)
  JSON.generate(result)
end

post "/promote" do
  content_type :json

  begin
    body = JSON.parse(request.body.read)
  rescue JSON::ParserError, TypeError
    invalid_input!
  end

  # ------------------------------------------------------------
  # Basic request validation
  # ------------------------------------------------------------

  unless body.is_a?(Hash) &&
         body["asOf"].is_a?(String) &&
         body["championVersion"].is_a?(String) &&
         body["policy"].is_a?(Hash) &&
         body["versions"].is_a?(Array)
    invalid_input!
  end

  as_of = parse_timestamp(body["asOf"])

  # Invalid asOf is invalid input rather than a model gate.
  invalid_input! if as_of.nil?

  policy = body["policy"]

  # A missing/invalid policy is an input problem.
  invalid_input! unless policy_valid?(policy)

  versions = body["versions"]

  # ------------------------------------------------------------
  # FIRST PASS:
  # Validate canonical IDs and detect duplicates BEFORE
  # constructing the lookup map.
  # ------------------------------------------------------------

  occurrences = Hash.new { |h, k| h[k] = 0 }
  versions_by_id = {}
  failures_by_version = {}

  versions.each do |version|
    id = version.is_a?(Hash) ? version["version"] : nil

    unless valid_version?(id)
      # String invalid IDs can still be reported by their value.
      # For non-string IDs, use a deterministic placeholder.
      key = id.is_a?(String) ? id : "__invalid__"

      failures_by_version[key] ||= []
      failures_by_version[key] << "INVALID_VERSION"
      next
    end

    occurrences[id] += 1

    # Do NOT overwrite the first occurrence.
    versions_by_id[id] ||= version
  end

  # ------------------------------------------------------------
  # Mark duplicate canonical IDs.
  # ------------------------------------------------------------

  occurrences.each do |id, count|
    next unless count > 1

    failures_by_version[id] ||= []
    failures_by_version[id] << "DUPLICATE_VERSION"
  end

  # ------------------------------------------------------------
  # Check each unique canonical version.
  # ------------------------------------------------------------

  versions_by_id.each do |id, version|
    failures_by_version[id] ||= []

    failures_by_version[id].concat(
      check_version(version, policy, as_of)
    )

    if occurrences[id] > 1
      failures_by_version[id] << "DUPLICATE_VERSION"
    end

    failures_by_version[id] =
      failures_by_version[id].uniq.sort
  end

  # Make sure every canonical version appears in failedGates,
  # INCLUDING versions with zero failures.
  versions_by_id.each_key do |id|
    failures_by_version[id] ||= []
    failures_by_version[id] =
      failures_by_version[id].uniq.sort
  end

  # ------------------------------------------------------------
  # Determine eligible versions.
  # ------------------------------------------------------------

  eligible_versions =
    versions_by_id.keys.select do |id|
      failures_by_version[id].empty?
    end

  # ------------------------------------------------------------
  # Deterministic ranking:
  # accuracy DESC
  # latency ASC
  # size ASC
  # numeric version ASC
  # ------------------------------------------------------------

  eligible_versions.sort_by! do |id|
    ranking_key(id, versions_by_id[id])
  end

  champion_id = body["championVersion"]

  # ------------------------------------------------------------
  # Champion must exist and be valid.
  # ------------------------------------------------------------

  unless valid_version?(champion_id) &&
         versions_by_id.key?(champion_id)

    champion_failures =
      failures_by_version[champion_id] ||
      ["INVALID_VERSION"]

    result = {
      "action" => "block",
      "championVersion" => champion_id,
      "selectedVersion" => nil,
      "eligibleVersions" => eligible_versions,
      "failedGates" => public_failed_gates(failures_by_version),
      "aliasMutation" => nil,
      "evidence" => nil
    }

    return json_response(result)
  end

  # ------------------------------------------------------------
  # Champion evidence must itself be valid.
  # ------------------------------------------------------------

  champion_failures = failures_by_version[champion_id]

  unless champion_failures.empty?
    result = {
      "action" => "block",
      "championVersion" => champion_id,
      "selectedVersion" => nil,
      "eligibleVersions" => eligible_versions,
      "failedGates" => public_failed_gates(failures_by_version),
      "aliasMutation" => nil,
      "evidence" => nil
    }

    return json_response(result)
  end

  champion_evaluation =
    versions_by_id[champion_id]["evaluation"]

  # ------------------------------------------------------------
  # Best eligible version.
  # ------------------------------------------------------------

  winner_id = eligible_versions.first

  # This should normally not happen because the champion is valid,
  # but retain safely if there is no eligible winner.
  if winner_id.nil?
    result = {
      "action" => "retain",
      "championVersion" => champion_id,
      "selectedVersion" => champion_id,
      "eligibleVersions" => eligible_versions,
      "failedGates" => public_failed_gates(failures_by_version),
      "aliasMutation" => nil,
      "evidence" => champion_evaluation
    }

    return json_response(result)
  end

  winner_evaluation =
    versions_by_id[winner_id]["evaluation"]

  champion_accuracy =
    champion_evaluation["accuracy"]

  winner_accuracy =
    winner_evaluation["accuracy"]

  improvement =
    (winner_accuracy - champion_accuracy).round(12)

  # ------------------------------------------------------------
  # Promote only if the winner is a different version and
  # meets the minimum improvement.
  # ------------------------------------------------------------

  if winner_id != champion_id &&
     improvement >= policy["minImprovement"]

    result = {
      "action" => "promote",
      "championVersion" => champion_id,
      "selectedVersion" => winner_id,
      "eligibleVersions" => eligible_versions,
      "failedGates" => public_failed_gates(failures_by_version),
      "aliasMutation" => {
        "alias" => "champion",
        "version" => winner_id
      },
      "evidence" => winner_evaluation
    }

    return json_response(result)
  end

  # ------------------------------------------------------------
  # Otherwise retain the champion.
  # ------------------------------------------------------------

  result = {
    "action" => "retain",
    "championVersion" => champion_id,
    "selectedVersion" => champion_id,
    "eligibleVersions" => eligible_versions,
    "failedGates" => public_failed_gates(failures_by_version),
    "aliasMutation" => nil,
    "evidence" => champion_evaluation
  }

  json_response(result)
end

get "/" do
  content_type :json

  JSON.generate(
    "service" => "MLflow deterministic promotion gate",
    "endpoint" => "POST /promote"
  )
end
