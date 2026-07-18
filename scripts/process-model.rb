#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"
require "yaml"
require "date"

ALLOWED_NODE_TYPES = %w[start end activity decision subprocess event document note].freeze
MAX_LABEL_LENGTH = 60

def usage!
  warn "Usage: #{$PROGRAM_NAME} validate|render-puml <process.yaml> [layout.yaml] [output.puml]"
  exit 2
end

def load_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [Date], aliases: false) || {}
rescue Psych::Exception => e
  raise "#{path}: invalid YAML: #{e.message}"
end

def actor_id(actor)
  actor.is_a?(Hash) ? actor.fetch("id") : actor.to_s
end

def actor_label(actor)
  actor.is_a?(Hash) ? actor.fetch("name", actor.fetch("label", actor.fetch("id"))) : actor.to_s
end

def actors_by_id(model)
  Array(model["actors"]).each_with_object({}) do |actor, memo|
    id = actor_id(actor)
    memo[id] = actor_label(actor)
  end
end

def nodes_by_id(model)
  Array(model["nodes"]).each_with_object({}) do |node, memo|
    memo[node.fetch("id")] = node
  end
end

def validate_model(model, path)
  errors = []
  process = model["process"]
  actors = Array(model["actors"])
  nodes = Array(model["nodes"])
  flows = Array(model["flows"])

  errors << "process.id is required" unless process.is_a?(Hash) && process["id"].to_s.strip != ""
  errors << "process.name is required" unless process.is_a?(Hash) && process["name"].to_s.strip != ""
  errors << "actors must not be empty" if actors.empty?
  errors << "nodes must not be empty" if nodes.empty?
  errors << "flows must not be empty" if flows.empty?

  actor_ids = actors.map { |actor| actor_id(actor) }
  duplicate_actor_ids = actor_ids.select { |id| actor_ids.count(id) > 1 }.uniq
  errors.concat(duplicate_actor_ids.map { |id| "duplicated actor id: #{id}" })

  node_ids = nodes.map { |node| node["id"] }
  duplicate_node_ids = node_ids.select { |id| node_ids.count(id) > 1 }.uniq
  errors.concat(duplicate_node_ids.map { |id| "duplicated node id: #{id}" })

  actor_lookup = actors_by_id(model)
  node_lookup = nodes_by_id(model)

  nodes.each do |node|
    id = node["id"].to_s
    type = node["type"].to_s
    label = node.fetch("label", id).to_s

    errors << "node without id" if id.strip == ""
    errors << "node #{id}: unsupported type #{type.inspect}" unless ALLOWED_NODE_TYPES.include?(type)
    errors << "node #{id}: label is too long (max #{MAX_LABEL_LENGTH})" if label.length > MAX_LABEL_LENGTH

    if %w[activity decision subprocess event document].include?(type)
      actor = node["actor"].to_s
      errors << "node #{id}: actor is required for #{type}" if actor.strip == ""
      errors << "node #{id}: unknown actor #{actor}" if actor.strip != "" && !actor_lookup.key?(actor)
    end
  end

  starts = nodes.select { |node| node["type"] == "start" }
  ends = nodes.select { |node| node["type"] == "end" }
  errors << "exactly one start node is required" unless starts.length == 1
  errors << "exactly one end node is required" unless ends.length == 1

  outgoing = Hash.new { |hash, key| hash[key] = [] }
  incoming = Hash.new { |hash, key| hash[key] = [] }

  flows.each do |flow|
    from = flow["from"].to_s
    to = flow["to"].to_s
    errors << "flow without from" if from.strip == ""
    errors << "flow without to" if to.strip == ""
    errors << "flow #{from} -> #{to}: source node does not exist" unless node_lookup.key?(from)
    errors << "flow #{from} -> #{to}: target node does not exist" unless node_lookup.key?(to)
    errors << "flow #{from} -> #{to}: label is too long (max #{MAX_LABEL_LENGTH})" if flow["label"].to_s.length > MAX_LABEL_LENGTH
    outgoing[from] << flow
    incoming[to] << flow
  end

  nodes.select { |node| node["type"] == "decision" }.each do |node|
    id = node["id"]
    decision_flows = outgoing[id]
    errors << "decision #{id}: at least two outgoing flows are required" if decision_flows.length < 2
    decision_flows.each do |flow|
      errors << "decision #{id}: outgoing flow to #{flow["to"]} needs a label" if flow["label"].to_s.strip == ""
    end
  end

  actors_with_work = nodes.map { |node| node["actor"] }.compact.to_set
  (actor_ids - actors_with_work.to_a).each do |id|
    errors << "actor #{id}: has no nodes"
  end

  if starts.length == 1
    reachable = Set.new
    queue = [starts.first["id"]]
    until queue.empty?
      current = queue.shift
      next if reachable.include?(current)

      reachable << current
      outgoing[current].each { |flow| queue << flow["to"] }
    end
    (node_ids - reachable.to_a).each { |id| errors << "node #{id}: is not reachable from start" }
  end

  if ends.length == 1
    reverse_reachable = Set.new
    queue = [ends.first["id"]]
    until queue.empty?
      current = queue.shift
      next if reverse_reachable.include?(current)

      reverse_reachable << current
      incoming[current].each { |flow| queue << flow["from"] }
    end
    (node_ids - reverse_reachable.to_a).each { |id| errors << "node #{id}: cannot reach end" }
  end

  return if errors.empty?

  raise "#{path} failed validation:\n- #{errors.join("\n- ")}"
end

def dot_id(id)
  id.to_s.gsub(/[^A-Za-z0-9_]/, "_")
end

def dot_string(value)
  "\"#{value.to_s.gsub("\\", "\\\\\\").gsub("\"", "\\\"").gsub("\n", "\\n")}\""
end

def render_puml(model, layout)
  process = model.fetch("process")
  actor_lookup = actors_by_id(model)
  nodes = Array(model["nodes"])
  flows = Array(model["flows"])
  direction = layout.fetch("direction", "LR")
  lane_order = Array(layout["lane-order"])
  ordered_actor_ids = (lane_order + actor_lookup.keys).uniq
  graph_id = dot_id(process.fetch("id"))

  node_shape = {
    "start" => "circle",
    "end" => "doublecircle",
    "activity" => "rect",
    "decision" => "diamond",
    "subprocess" => "component",
    "event" => "oval",
    "document" => "note",
    "note" => "note"
  }

  lines = []
  lines << "' Generated from process.yaml. Do not edit manually."
  lines << "@startdot"
  lines << "digraph #{graph_id} {"
  lines << "  graph ["
  lines << "    label=#{dot_string(process.fetch("name"))},"
  lines << "    labelloc=t,"
  lines << "    fontsize=18,"
  lines << "    fontname=\"Arial\","
  lines << "    rankdir=#{direction},"
  lines << "    splines=polyline,"
  lines << "    nodesep=0.55,"
  lines << "    ranksep=0.9,"
  lines << "    compound=true,"
  lines << "    bgcolor=\"white\""
  lines << "  ];"
  lines << ""
  lines << "  node [shape=rect, style=\"rounded,filled\", fillcolor=\"#f7f8fa\", color=\"#4f5b67\", fontcolor=\"#1f2933\", fontname=\"Arial\", fontsize=11, margin=\"0.12,0.08\"];"
  lines << "  edge [color=\"#4f5b67\", fontname=\"Arial\", fontsize=10, arrowsize=0.7];"
  lines << ""

  ordered_actor_ids.each do |actor|
    actor_nodes = nodes.select { |node| node["actor"] == actor }
    next if actor_nodes.empty?

    lines << "  subgraph cluster_#{dot_id(actor)} {"
    lines << "    label=#{dot_string(actor_lookup.fetch(actor))};"
    lines << "    style=\"rounded,filled\";"
    lines << "    color=\"#7a8da8\";"
    lines << "    fillcolor=\"#eef4ff\";"
    lines << "    fontname=\"Arial\";"
    lines << "    fontsize=13;"
    lines << ""
    actor_nodes.each do |node|
      attrs = {
        "label" => node.fetch("label", node.fetch("id")),
        "shape" => node_shape.fetch(node.fetch("type"))
      }
      attrs["width"] = "1.45" if node["type"] == "decision"
      attrs["height"] = "0.55" if node["type"] == "decision"
      rendered = attrs.map { |key, value| "#{key}=#{dot_string(value)}" }.join(", ")
      lines << "    #{dot_id(node.fetch("id"))} [#{rendered}];"
    end
    lines << "  }"
    lines << ""
  end

  system_nodes = nodes.reject { |node| actor_lookup.key?(node["actor"]) }
  system_nodes.each do |node|
    attrs = {
      "label" => %w[start end].include?(node["type"]) ? "" : node.fetch("label", node.fetch("id")),
      "shape" => node_shape.fetch(node.fetch("type"))
    }
    if node["type"] == "start"
      attrs.merge!("width" => "0.18", "height" => "0.18", "fillcolor" => "#222222", "color" => "#222222")
    elsif node["type"] == "end"
      attrs.merge!("width" => "0.18", "height" => "0.18", "fillcolor" => "#222222", "color" => "#222222")
    end
    rendered = attrs.map { |key, value| "#{key}=#{dot_string(value)}" }.join(", ")
    lines << "  #{dot_id(node.fetch("id"))} [#{rendered}];"
  end
  lines << ""

  flows.each do |flow|
    label = flow["label"].to_s.strip
    attrs = label == "" ? "" : " [xlabel=#{dot_string(label)}]"
    lines << "  #{dot_id(flow.fetch("from"))} -> #{dot_id(flow.fetch("to"))}#{attrs};"
  end

  lines << "}"
  lines << "@enddot"
  lines << ""
  lines.join("\n")
end

command, process_path, layout_path, output_path = ARGV
usage! unless %w[validate render-puml].include?(command) && process_path

model = load_yaml(process_path)
layout = layout_path && File.exist?(layout_path) ? load_yaml(layout_path) : {}
validate_model(model, process_path)

case command
when "validate"
  puts "#{process_path}: ok"
when "render-puml"
  usage! unless output_path
  File.write(output_path, render_puml(model, layout))
end
