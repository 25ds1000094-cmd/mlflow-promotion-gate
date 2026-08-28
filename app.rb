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

def check_version(version, policy, as_of, policy_is_valid)
  failures = []

  unless policy_is_valid
    failures << "INVALID_POLICY"
  end

  unless version.is_a?(Hash)
    failures << "INVALID_VERSION"
    return failures.uniq.sort
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

  created_at = parse_timestamp(evaluation["createdAt"])

  if created_at.nil?
    failures << "INVALID_TIMESTAMP"
  else
    if created_at > as_of
      failures << "FUTURE_EVALUATION"
    elsif policy_is_valid &&
          created_at < as_of - policy["maxAgeSeconds"]
      failures << "STALE_EVALUATION"
    end
  end

  if evaluation["artifactDigest"] != version["artifactDigest"]
    failures << "ARTIFACT_MISMATCH"
  end

  if policy_is_valid &&
     evaluation["datasetDigest"] != policy["datasetDigest"]
    failures << "DATASET_MISMATCH"
  end

  if policy_is_valid &&
     evaluation["schemaDigest"] != policy["schemaDigest"]
    failures << "SCHEMA_MISMATCH"
  end

  accuracy = evaluation["accuracy"]
  latency = evaluation["latencyMs"]
  size = evaluation["sizeBytes"]

  unless finite_number?(accuracy) &&
         finite_number?(latency) &&
         finite_number?(size)
    failures << "NON_FINITE"
  else
    unless accuracy.between?(0.0, 1.0)
      failures << "METRIC_RANGE"
    end

    unless latency >= 0
      failures << "METRIC_RANGE"
    end

    unless safe_non_negative_integer?(size)
      failures << "METRIC_RANGE"
    end
  end

  if policy_is_valid &&
     finite_number?(accuracy) &&
     accuracy.between?(0.0, 1.0) &&
     accuracy < policy["accuracyFloor"]
    failures << "ACCURACY_FLOOR"
  end

  if policy_is_valid &&
     finite_number?(latency) &&
     latency >= 0 &&
     latency > policy["maxLatencyMs"]
    failures << "LATENCY_LIMIT"
  end

  if policy_is_valid &&
     safe_non_negative_integer?(size) &&
     size > policy["maxSizeBytes"]
    failures << "SIZE_LIMIT"
  end

  slices = evaluation["slices"]

  if policy_is_valid
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
  failures_by_version.transform_values do |codes|
    codes.uniq.sort
  end
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

  unless body.is_a?(Hash) &&
         body["asOf"].is_a?(String) &&
         body["championVersion"].is_a?(String) &&
         body.key?("policy") &&
         body["versions"].is_a?(Array)
    invalid_input!
  end

  as_of = parse_timestamp(body["asOf"])
  invalid_input! if as_of.nil?

  policy = body["policy"]
  policy_is_valid = policy_valid?(policy)

  versions = body["versions"]

  occurrences = Hash.new { |h, k| h[k] = 0 }
  versions_by_id = {}
  failures_by_version = {}

  versions.each do |version|
    id = version.is_a?(Hash) ? version["version"] : nil

    unless valid_version?(id)
      key = id.is_a?(String) ? id : "__invalid__"

      failures_by_version[key] ||= []
      failures_by_version[key] << "INVALID_VERSION"
      next
    end

    occurrences[id] += 1

    versions_by_id[id] ||= version
  end

  occurrences.each do |id, count|
    next unless count > 1

    failures_by_version[id] ||= []
    failures_by_version[id] << "DUPLICATE_VERSION"
  end

  versions_by_id.each do |id, version|
    failures_by_version[id] ||= []

    failures_by_version[id].concat(
      check_version(
        version,
        policy,
        as_of,
        policy_is_valid
      )
    )

    if occurrences[id] > 1
      failures_by_version[id] << "DUPLICATE_VERSION"
    end

    failures_by_version[id] =
      failures_by_version[id].uniq.sort
  end

  versions_by_id.each_key do |id|
    failures_by_version[id] ||= []
    failures_by_version[id] =
      failures_by_version[id].uniq.sort
  end

  eligible_versions =
    versions_by_id.keys.select do |id|
      failures_by_version[id].empty?
    end

  eligible_versions.sort_by! do |id|
    ranking_key(id, versions_by_id[id])
  end

  champion_id = body["championVersion"]

  unless valid_version?(champion_id) &&
         versions_by_id.key?(champion_id)

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

  winner_id = eligible_versions.first

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