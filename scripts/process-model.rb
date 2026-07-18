#!/usr/bin/env ruby
# frozen_string_literal: true

require "set"
require "yaml"
require "date"

ALLOWED_NODE_TYPES = %w[start end activity decision subprocess event document note].freeze
MAX_LABEL_LENGTH = 60

def usage!
  warn "Usage: #{$PROGRAM_NAME} validate|render-svg <process.yaml> [layout.yaml] [output.svg]"
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

def xml_escape(value)
  value.to_s
       .gsub("&", "&amp;")
       .gsub("<", "&lt;")
       .gsub(">", "&gt;")
       .gsub("\"", "&quot;")
end

def wrap_label(label, max_chars = 18)
  words = label.to_s.split
  return [""] if words.empty?

  lines = []
  current = +""
  words.each do |word|
    candidate = current.empty? ? word : "#{current} #{word}"
    if candidate.length > max_chars && !current.empty?
      lines << current
      current = word
    else
      current = candidate
    end
  end
  lines << current unless current.empty?
  lines
end

def render_svg(model, layout)
  process = model.fetch("process")
  actor_lookup = actors_by_id(model)
  nodes = Array(model["nodes"])
  flows = Array(model["flows"])
  node_lookup = nodes_by_id(model)
  lane_order = Array(layout["lane-order"])
  ordered_actor_ids = (lane_order.select { |actor| actor_lookup.key?(actor) } + actor_lookup.keys).uniq

  incoming = Hash.new { |hash, key| hash[key] = [] }
  outgoing = Hash.new { |hash, key| hash[key] = [] }
  flows.each do |flow|
    outgoing[flow.fetch("from")] << flow
    incoming[flow.fetch("to")] << flow
  end

  lane_for_node = lambda do |node|
    actor = node["actor"]
    return actor if actor_lookup.key?(actor)

    if node["type"] == "start"
      target = outgoing[node.fetch("id")].map { |flow| node_lookup[flow["to"]] }.compact.find { |candidate| candidate["actor"] }
      return target["actor"] if target
    end

    source = incoming[node.fetch("id")].map { |flow| node_lookup[flow["from"]] }.compact.find { |candidate| candidate["actor"] }
    source ? source["actor"] : ordered_actor_ids.first
  end

  lane_ids = ordered_actor_ids.select do |actor|
    nodes.any? { |node| lane_for_node.call(node) == actor }
  end

  margin = 24
  title_height = 56
  actor_col_width = 76
  lane_height = Integer(layout.fetch("lane-height", 116))
  column_width = Integer(layout.fetch("column-width", 188))
  node_area_padding = 44
  activity_width = 142
  activity_height = 52
  decision_width = 124
  decision_height = 72
  terminal_size = 30

  node_index = nodes.each_with_index.to_h
  node_positions = {}
  lane_index = lane_ids.each_with_index.to_h
  nodes.each do |node|
    lane = lane_for_node.call(node)
    column = node_index.fetch(node)
    x = margin + actor_col_width + node_area_padding + (column * column_width)
    y = margin + title_height + (lane_index.fetch(lane) * lane_height) + (lane_height / 2.0)
    node_positions[node.fetch("id")] = [x, y]
  end

  content_width = node_area_padding * 2 + ((nodes.length - 1) * column_width) + activity_width
  width = margin * 2 + actor_col_width + content_width
  height = margin * 2 + title_height + (lane_ids.length * lane_height)

  shape_size = lambda do |node|
    case node["type"]
    when "start", "end"
      [terminal_size, terminal_size]
    when "decision"
      [decision_width, decision_height]
    else
      [activity_width, activity_height]
    end
  end

  edge_anchor = lambda do |node, side|
    x, y = node_positions.fetch(node.fetch("id"))
    w, h = shape_size.call(node)
    case side
    when :left then [x - (w / 2.0), y]
    when :right then [x + (w / 2.0), y]
    when :top then [x, y - (h / 2.0)]
    when :bottom then [x, y + (h / 2.0)]
    end
  end

  lines = []
  lines << %(<?xml version="1.0" encoding="UTF-8"?>)
  lines << %(<svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" role="img" aria-labelledby="title desc">)
  lines << %(  <title id="title">#{xml_escape(process.fetch("name"))}</title>)
  lines << %(  <desc id="desc">Diagrama generado desde process.yaml con lanes horizontales, actores a la izquierda, tamanos fijos y conectores ortogonales.</desc>)
  lines << %(  <defs>)
  lines << %(    <marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto-start-reverse">)
  lines << %(      <path d="M 0 0 L 10 5 L 0 10 z" fill="#4f5b67"/>)
  lines << %(    </marker>)
  lines << %(  </defs>)
  lines << %(  <rect x="#{margin}" y="#{margin}" width="#{width - (margin * 2)}" height="#{height - (margin * 2)}" rx="0" fill="#ffffff" stroke="#4f5b67" stroke-width="1.5"/>)
  lines << %(  <text x="#{width / 2.0}" y="#{margin + 32}" text-anchor="middle" font-family="Arial, sans-serif" font-size="20" font-weight="700" fill="#1f2933">#{xml_escape(process.fetch("name"))}</text>)

  lane_ids.each_with_index do |actor, index|
    y = margin + title_height + (index * lane_height)
    fill = index.even? ? "#f8fafc" : "#eef4ff"
    lines << %(  <rect x="#{margin}" y="#{y}" width="#{width - (margin * 2)}" height="#{lane_height}" fill="#{fill}" stroke="#d5dce6" stroke-width="1"/>)
    lines << %(  <rect x="#{margin}" y="#{y}" width="#{actor_col_width}" height="#{lane_height}" fill="#e6edf7" stroke="#d5dce6" stroke-width="1"/>)
    actor_x = margin + (actor_col_width / 2.0)
    actor_y = y + (lane_height / 2.0)
    lines << %(  <text x="#{actor_x}" y="#{actor_y}" text-anchor="middle" dominant-baseline="middle" transform="rotate(-90 #{actor_x} #{actor_y})" font-family="Arial, sans-serif" font-size="13" font-weight="700" fill="#1f2933">#{xml_escape(actor_lookup.fetch(actor))}</text>)
  end

  lines << %(  <g fill="none" stroke="#4f5b67" stroke-width="1.4" marker-end="url(#arrow)">)
  flows.each do |flow|
    from_node = node_lookup.fetch(flow.fetch("from"))
    to_node = node_lookup.fetch(flow.fetch("to"))
    from_x, from_y = node_positions.fetch(from_node.fetch("id"))
    to_x, to_y = node_positions.fetch(to_node.fetch("id"))

    if to_x >= from_x
      start = edge_anchor.call(from_node, :right)
      finish = edge_anchor.call(to_node, :left)
      mid_x = ((start[0] + finish[0]) / 2.0).round(2)
      points = [[start[0], start[1]], [mid_x, start[1]], [mid_x, finish[1]], [finish[0], finish[1]]]
    else
      start = edge_anchor.call(from_node, :left)
      finish = edge_anchor.call(to_node, :right)
      route_x = [start[0], finish[0]].min - 36
      points = [[start[0], start[1]], [route_x, start[1]], [route_x, finish[1]], [finish[0], finish[1]]]
    end

    compact_points = points.each_with_object([]) do |point, memo|
      memo << point unless memo.last == point
    end
    lines << %(    <polyline points="#{compact_points.map { |x, y| "#{x.round(2)},#{y.round(2)}" }.join(" ")}"/>)
  end
  lines << %(  </g>)

  flows.each do |flow|
    label = flow["label"].to_s.strip
    next if label.empty?

    from_x, from_y = node_positions.fetch(flow.fetch("from"))
    to_x, to_y = node_positions.fetch(flow.fetch("to"))
    label_x = ((from_x + to_x) / 2.0).round(2)
    label_y = ((from_y + to_y) / 2.0).round(2) - 8
    text_width = [label.length * 7 + 12, 26].max
    lines << %(  <rect x="#{label_x - (text_width / 2.0)}" y="#{label_y - 13}" width="#{text_width}" height="18" fill="#ffffff" stroke="none"/>)
    lines << %(  <text x="#{label_x}" y="#{label_y}" text-anchor="middle" font-family="Arial, sans-serif" font-size="11" fill="#1f2933">#{xml_escape(label)}</text>)
  end

  nodes.each do |node|
    x, y = node_positions.fetch(node.fetch("id"))
    w, h = shape_size.call(node)
    label = node.fetch("label", node.fetch("id"))

    case node["type"]
    when "start"
      lines << %(  <circle cx="#{x}" cy="#{y}" r="#{terminal_size / 2.0}" fill="#1f2933" stroke="#1f2933" stroke-width="1.5"/>)
    when "end"
      lines << %(  <circle cx="#{x}" cy="#{y}" r="#{terminal_size / 2.0}" fill="#ffffff" stroke="#1f2933" stroke-width="2"/>)
      lines << %(  <circle cx="#{x}" cy="#{y}" r="#{(terminal_size / 2.0) - 5}" fill="#1f2933" stroke="none"/>)
    when "decision"
      points = [[x, y - (h / 2.0)], [x + (w / 2.0), y], [x, y + (h / 2.0)], [x - (w / 2.0), y]]
      lines << %(  <polygon points="#{points.map { |px, py| "#{px},#{py}" }.join(" ")}" fill="#ffffff" stroke="#4f5b67" stroke-width="1.5"/>)
      wrap_label(label, 15).each_with_index do |text, index|
        offset = (index - ((wrap_label(label, 15).length - 1) / 2.0)) * 13
        lines << %(  <text x="#{x}" y="#{y + offset + 4}" text-anchor="middle" font-family="Arial, sans-serif" font-size="11" fill="#1f2933">#{xml_escape(text)}</text>)
      end
    else
      lines << %(  <rect x="#{x - (w / 2.0)}" y="#{y - (h / 2.0)}" width="#{w}" height="#{h}" rx="4" fill="#ffffff" stroke="#4f5b67" stroke-width="1.5"/>)
      label_lines = wrap_label(label)
      label_lines.each_with_index do |text, index|
        offset = (index - ((label_lines.length - 1) / 2.0)) * 14
        lines << %(  <text x="#{x}" y="#{y + offset + 4}" text-anchor="middle" font-family="Arial, sans-serif" font-size="12" fill="#1f2933">#{xml_escape(text)}</text>)
      end
    end
  end

  lines << %(</svg>)
  lines << ""
  lines.join("\n")
end

def view_phases(layout)
  Array(layout.dig("views", "phases"))
end

def views_enabled?(layout)
  !view_phases(layout).empty?
end

def render_output_path(process_dir, name)
  File.join(process_dir, name)
end

def render_view_outputs(layout)
  return [] unless views_enabled?(layout)

  outputs = ["process-overview.svg"]
  outputs.concat(view_phases(layout).map { |phase| "process-#{phase.fetch("id")}.svg" })
  outputs
end

def overview_model(model, layout)
  phases = view_phases(layout)
  actors = [{ "id" => "process", "name" => "Proceso" }]
  nodes = [{ "id" => "start", "type" => "start" }]
  nodes.concat(phases.map do |phase|
    {
      "id" => phase.fetch("id"),
      "actor" => "process",
      "type" => "subprocess",
      "label" => phase.fetch("label")
    }
  end)
  nodes << { "id" => "end", "type" => "end" }

  flow_nodes = nodes.map { |node| node.fetch("id") }
  flows = flow_nodes.each_cons(2).map { |from, to| { "from" => from, "to" => to } }

  {
    "process" => {
      "id" => "#{model.fetch("process").fetch("id")}-overview",
      "name" => "#{model.fetch("process").fetch("name")} - vista general"
    },
    "actors" => actors,
    "nodes" => nodes,
    "flows" => flows
  }
end

def phase_model(model, phase)
  node_lookup = nodes_by_id(model)
  selected_ids = Array(phase.fetch("nodes")).map(&:to_s)
  selected = selected_ids.map { |id| node_lookup.fetch(id) }
  selected_set = selected_ids.to_set

  internal_flows = Array(model["flows"]).select do |flow|
    selected_set.include?(flow.fetch("from")) && selected_set.include?(flow.fetch("to"))
  end

  incoming_internal = Hash.new { |hash, key| hash[key] = [] }
  outgoing_internal = Hash.new { |hash, key| hash[key] = [] }
  internal_flows.each do |flow|
    outgoing_internal[flow.fetch("from")] << flow
    incoming_internal[flow.fetch("to")] << flow
  end

  entry_ids = selected_ids.select { |id| incoming_internal[id].empty? }
  exit_ids = selected_ids.select { |id| outgoing_internal[id].empty? }
  entry_ids = [selected_ids.first] if entry_ids.empty?
  exit_ids = [selected_ids.last] if exit_ids.empty?

  flows = entry_ids.map { |id| { "from" => "start", "to" => id } }
  flows.concat(internal_flows)
  flows.concat(exit_ids.map { |id| { "from" => id, "to" => "end" } })

  actors = Array(model["actors"]).select do |actor|
    actor_id_value = actor_id(actor)
    selected.any? { |node| node["actor"] == actor_id_value }
  end

  {
    "process" => {
      "id" => "#{model.fetch("process").fetch("id")}-#{phase.fetch("id")}",
      "name" => phase.fetch("label")
    },
    "actors" => actors,
    "nodes" => [{ "id" => "start", "type" => "start" }] + selected + [{ "id" => "end", "type" => "end" }],
    "flows" => flows
  }
end

def render_document_views(model, layout, output_dir)
  return unless views_enabled?(layout)

  overview_layout = layout.merge(
    "lane-order" => ["process"],
    "lane-height" => layout.fetch("overview-lane-height", 150),
    "column-width" => layout.fetch("overview-column-width", 240)
  )
  File.write(
    render_output_path(output_dir, "process-overview.svg"),
    render_svg(overview_model(model, layout), overview_layout)
  )

  view_phases(layout).each do |phase|
    phase_layout = layout.merge(
      "lane-height" => layout.fetch("phase-lane-height", 144),
      "column-width" => layout.fetch("phase-column-width", 178)
    )
    File.write(
      render_output_path(output_dir, "process-#{phase.fetch("id")}.svg"),
      render_svg(phase_model(model, phase), phase_layout)
    )
  end
end

command, process_path, layout_path, output_path = ARGV
usage! unless %w[validate render-svg render-document-views list-document-views].include?(command) && process_path

model = load_yaml(process_path)
layout = layout_path && File.exist?(layout_path) ? load_yaml(layout_path) : {}
validate_model(model, process_path)

case command
when "validate"
  puts "#{process_path}: ok"
when "render-svg"
  usage! unless output_path
  File.write(output_path, render_svg(model, layout))
when "render-document-views"
  usage! unless output_path
  render_document_views(model, layout, output_path)
when "list-document-views"
  puts render_view_outputs(layout)
end
