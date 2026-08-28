require "sinatra"
require "json"
require "time"

MAX_SAFE_INTEGER = 9_007_199_254_740_991

TIMESTAMP_RE =
  /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?(?:Z|[+-]\d{2}:\d{2})\z/

GATE_CODES = [
  "INVALID_VERSION",
  "DUPLICATE_VERSION",
  "INVALID_POLICY",
  "MISSING_EVALUATION",
  "NON_FINITE",
  "METRIC_RANGE",
  "INVALID_TIMESTAMP",
  "FUTURE_EVALUATION",
  "STALE_EVALUATION",
  "ARTIFACT_MISMATCH",
  "DATASET_MISMATCH",
  "SCHEMA_MISMATCH",
  "ACCURACY_FLOOR",
  "LATENCY_LIMIT",
  "SIZE_LIMIT"
].freeze

def invalid_input!
  halt 400, { "Content-Type" => "application/json" },
       JSON.generate("error" => "INVALID_INPUT")
end

def valid_version?(value)
  return false unless value.is_a?(String)
  return false unless value.match?(/\A[1-9][0-9]*\z/)

  number = value.to_i
  number >= 1 && number <= MAX_SAFE_INTEGER
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

def non_negative_safe_integer?(value)
  value.is_a?(Integer) &&
    value >= 0 &&
    value <= MAX_SAFE_INTEGER
end

def add_failure(failures, code)
  failures << code
end

def check_policy(policy)
  failures = []

  unless policy.is_a?(Hash)
    return ["INVALID_POLICY"]
  end

  required_keys = %w[
    datasetDigest
    schemaDigest
    maxAgeSeconds
    accuracyFloor
    requiredSlices
    maxLatencyMs
    maxSizeBytes
    minImprovement
  ]

  unless required_keys.all? { |key| policy.key?(key) }
    return ["INVALID_POLICY"]
  end

  unless policy["datasetDigest"].is_a?(String) &&
         !policy["datasetDigest"].empty?
    failures << "INVALID_POLICY"
  end

  unless policy["schemaDigest"].is_a?(String) &&
         !policy["schemaDigest"].empty?
    failures << "INVALID_POLICY"
  end

  unless non_negative_safe_integer?(policy["maxAgeSeconds"])
    failures << "INVALID_POLICY"
  end

  unless finite_number?(policy["accuracyFloor"]) &&
         policy["accuracyFloor"].between?(0.0, 1.0)
    failures << "INVALID_POLICY"
  end

  unless finite_number?(policy["minImprovement"]) &&
         policy["minImprovement"].between?(0.0, 1.0)
    failures << "INVALID_POLICY"
  end

  unless non_negative_safe_integer?(policy["maxLatencyMs"])
    failures << "INVALID_POLICY"
  end

  unless non_negative_safe_integer?(policy["maxSizeBytes"])
    failures << "INVALID_POLICY"
  end

  unless policy["requiredSlices"].is_a?(Hash)
    failures << "INVALID_POLICY"
  else
    policy["requiredSlices"].each do |name, floor|
      unless name.is_a?(String) &&
             finite_number?(floor) &&
             floor.between?(0.0, 1.0)
        failures << "INVALID_POLICY"
      end
    end
  end

  failures.uniq.sort
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

  artifact_digest = version["artifactDigest"]

  evaluation = version["evaluation"]

  if !evaluation.is_a?(Hash)
    failures << "MISSING_EVALUATION"
    return failures.uniq.sort
  end

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

  if evaluation["artifactDigest"] != artifact_digest
    failures << "ARTIFACT_MISMATCH"
  end

  if evaluation["datasetDigest"] != policy["datasetDigest"]
    failures << "DATASET_MISMATCH"
  end

  if evaluation["schemaDigest"] != policy["schemaDigest"]
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
    unless accuracy.between?(0.0, 1.0) &&
           latency >= 0 &&
           size >= 0
      failures << "METRIC_RANGE"
    end
  end

  unless non_negative_safe_integer?(size)
    failures << "METRIC_RANGE" if finite_number?(size)
  end

  unless non_negative_safe_integer?(latency)
    failures << "METRIC_RANGE" if finite_number?(latency)
  end

  if finite_number?(accuracy) &&
     accuracy.between?(0.0, 1.0) &&
     accuracy < policy["accuracyFloor"]
    failures << "ACCURACY_FLOOR"
  end

  if finite_number?(latency) &&
     latency >= 0 &&
     latency > policy["maxLatencyMs"]
    failures << "LATENCY_LIMIT"
  end

  if finite_number?(size) &&
     size >= 0 &&
     size <= MAX_SAFE_INTEGER &&
     size > policy["maxSizeBytes"]
    failures << "SIZE_LIMIT"
  end

  slices = evaluation["slices"]

  unless slices.is_a?(Hash)
    policy["requiredSlices"].each_key do |name|
      failures << "MISSING_SLICE:#{name}"
    end
  else
    policy["requiredSlices"].each do |name, floor|
      unless slices.key?(name)
        failures << "MISSING_SLICE:#{name}"
        next
      end

      value = slices[name]

      unless finite_number?(value)
        failures << "SLICE_RANGE:#{name}"
        next
      end

      unless value.between?(0.0, 1.0)
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

def rounded_difference(challenger_accuracy, champion_accuracy)
  ((challenger_accuracy - champion_accuracy).round(12))
end

post "/promote" do
  content_type :json

  begin
    raw_body = request.body.read
    body = JSON.parse(raw_body)
  rescue JSON::ParserError, TypeError
    invalid_input!
  end

  unless body.is_a?(Hash) &&
         body["asOf"].is_a?(String) &&
         body["championVersion"].is_a?(String) &&
         body["policy"].is_a?(Hash) &&
         body["versions"].is_a?(Array)
    invalid_input!
  end

  as_of = parse_timestamp(body["asOf"])
  invalid_input! if as_of.nil?

  policy = body["policy"]
  policy_failures = check_policy(policy)

  if policy_failures.any?
    result = {
      "action" => "block",
      "championVersion" => body["championVersion"],
      "selectedVersion" => nil,
      "eligibleVersions" => [],
      "failedGates" => {
        "_policy" => policy_failures
      },
      "aliasMutation" => nil,
      "evidence" => nil
    }

    return JSON.generate(result)
  end

  versions = body["versions"]

  failures_by_version = {}
  versions_by_id = {}
  duplicate_ids = {}

  # First pass: validate every version ID and detect duplicates.
  versions.each do |version|
    id = version.is_a?(Hash) ? version["version"] : nil

    unless valid_version?(id)
      key = id.is_a?(String) ? id : "__invalid__"
      failures_by_version[key] ||= []
      failures_by_version[key] << "INVALID_VERSION"
      next
    end

    if versions_by_id.key?(id)
      duplicate_ids[id] = true
    else
      versions_by_id[id] = version
    end
  end

  # Mark duplicates without allowing one duplicate to overwrite another.
  duplicate_ids.each do |id|
    failures_by_version[id] ||= []
    failures_by_version[id] << "DUPLICATE_VERSION"
  end

  # Check every unique valid version.
  versions_by_id.each do |id, version|
    failures = check_version(version, policy, as_of)

    if duplicate_ids[id]
      failures << "DUPLICATE_VERSION"
    end

    failures_by_version[id] ||= []
    failures_by_version[id].concat(failures)
    failures_by_version[id] = failures_by_version[id].uniq.sort
  end

  # Ensure every malformed version occurrence contributes a deterministic
  # failure. Invalid version IDs cannot safely be used as lookup keys.
  invalid_occurrences = versions.select do |version|
    id = version.is_a?(Hash) ? version["version"] : nil
    !valid_version?(id)
  end

  invalid_occurrences.each do |version|
    id = version.is_a?(Hash) && version["version"].is_a?(String) ?
           version["version"] : "__invalid__"

    failures_by_version[id] ||= []
    failures_by_version[id] << "INVALID_VERSION"
    failures_by_version[id] = failures_by_version[id].uniq.sort
  end

  eligible_versions = versions_by_id.keys.select do |id|
    failures_by_version[id].empty?
  end

  eligible_versions.sort_by! do |id|
    evaluation = versions_by_id[id]["evaluation"]

    [
      -evaluation["accuracy"],
      evaluation["latencyMs"],
      evaluation["sizeBytes"],
      id.to_i
    ]
  end

  champion_id = body["championVersion"]

  unless valid_version?(champion_id) &&
         versions_by_id.key?(champion_id)
    failed = failures_by_version[champion_id] || ["INVALID_VERSION"]

    result = {
      "action" => "block",
      "championVersion" => champion_id,
      "selectedVersion" => nil,
      "eligibleVersions" => eligible_versions,
      "failedGates" => {
        champion_id => failed.uniq.sort
      },
      "aliasMutation" => nil,
      "evidence" => nil
    }

    return JSON.generate(result)
  end

  champion_failures = failures_by_version[champion_id] || []

  unless champion_failures.empty?
    result = {
      "action" => "block",
      "championVersion" => champion_id,
      "selectedVersion" => nil,
      "eligibleVersions" => eligible_versions,
      "failedGates" => failures_by_version
        .select { |_, codes| !codes.empty? }
        .transform_values { |codes| codes.uniq.sort },
      "aliasMutation" => nil,
      "evidence" => nil
    }

    return JSON.generate(result)
  end

  # Champion is valid. The best eligible model is the winner.
  winner_id = eligible_versions.first

  # If no eligible version exists, safely retain the champion.
  if winner_id.nil?
    result = {
      "action" => "retain",
      "championVersion" => champion_id,
      "selectedVersion" => champion_id,
      "eligibleVersions" => eligible_versions,
      "failedGates" => failures_by_version
        .select { |_, codes| !codes.empty? }
        .transform_values { |codes| codes.uniq.sort },
      "aliasMutation" => nil,
      "evidence" => versions_by_id[champion_id]["evaluation"]
    }

    return JSON.generate(result)
  end

  champion_accuracy =
    versions_by_id[champion_id]["evaluation"]["accuracy"]

  winner_accuracy =
    versions_by_id[winner_id]["evaluation"]["accuracy"]

  improvement =
    rounded_difference(winner_accuracy, champion_accuracy)

  if winner_id != champion_id &&
     improvement >= policy["minImprovement"]

    result = {
      "action" => "promote",
      "championVersion" => champion_id,
      "selectedVersion" => winner_id,
      "eligibleVersions" => eligible_versions,
      "failedGates" => failures_by_version
        .select { |_, codes| !codes.empty? }
        .transform_values { |codes| codes.uniq.sort },
      "aliasMutation" => {
        "alias" => "champion",
        "version" => winner_id
      },
      "evidence" => versions_by_id[winner_id]["evaluation"]
    }

    JSON.generate(result)
  else
    result = {
      "action" => "retain",
      "championVersion" => champion_id,
      "selectedVersion" => champion_id,
      "eligibleVersions" => eligible_versions,
      "failedGates" => failures_by_version
        .select { |_, codes| !codes.empty? }
        .transform_values { |codes| codes.uniq.sort },
      "aliasMutation" => nil,
      "evidence" => versions_by_id[champion_id]["evaluation"]
    }

    JSON.generate(result)
  end
end

get "/" do
  content_type :json
  JSON.generate(
    "service" => "MLflow deterministic promotion gate",
    "endpoint" => "POST /promote"
  )
end
