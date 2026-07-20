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

def svg_multiline_text(lines, x:, y:, line_height:, **attributes)
  attributes_text = attributes.map { |name, value| %(#{name}="#{value}") }.join(" ")
  first_offset = -((lines.length - 1) * line_height / 2.0)
  tspans = lines.each_with_index.map do |line, index|
    dy = index.zero? ? first_offset : line_height
    %(<tspan x="#{x}" dy="#{dy}">#{xml_escape(line)}</tspan>)
  end
  %(<text x="#{x}" y="#{y}" #{attributes_text}>#{tspans.join}</text>)
end

def layout_nodes(nodes, flows)
  # Conserva el orden declarado siempre que sea posible, pero sitúa cualquier
  # destino de "Sí" después de su decisión. Así esta salida nunca retrocede.
  ordered = nodes.dup
  yes_flows = flows.select do |flow|
    %w[si sí].include?(flow["label"].to_s.strip.downcase)
  end

  nodes.length.times do
    changed = false
    yes_flows.each do |flow|
      from_index = ordered.index { |node| node.fetch("id") == flow.fetch("from") }
      to_index = ordered.index { |node| node.fetch("id") == flow.fetch("to") }
      next unless from_index && to_index && to_index <= from_index

      target = ordered.delete_at(to_index)
      from_index -= 1 if to_index < from_index
      ordered.insert(from_index + 1, target)
      changed = true
    end
    break unless changed
  end

  ordered
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
  actor_col_width = 120
  lane_height = Integer(layout.fetch("lane-height", 116))
  column_width = Integer(layout.fetch("column-width", 188))
  node_area_padding = 44
  activity_width = 142
  activity_height = 52
  decision_width = 124
  decision_height = 72
  terminal_size = 30

  positioned_nodes = layout_nodes(nodes, flows)
  node_index = positioned_nodes.each_with_index.to_h
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
  # Los retornos se trazan por debajo de las swimlanes para que no atraviesen
  # actividades ni interfieran con el avance principal de izquierda a derecha.
  feedback_flows = flows.select do |flow|
    from_index = node_index.fetch(node_lookup.fetch(flow.fetch("from")))
    to_index = node_index.fetch(node_lookup.fetch(flow.fetch("to")))
    to_index < from_index
  end
  feedback_area_height = feedback_flows.length * 24 + (feedback_flows.empty? ? 0 : 28)
  lane_bottom = margin + title_height + (lane_ids.length * lane_height)
  height = margin * 2 + title_height + (lane_ids.length * lane_height) + feedback_area_height

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
  lines << %(  <desc id="desc">Diagrama generado desde process.yaml con swimlanes horizontales, etiquetas de actor en varias lineas y conectores octolineales sin cruces deliberados.</desc>)
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
    actor_text = svg_multiline_text(
      wrap_label(actor_lookup.fetch(actor), 16), x: actor_x, y: actor_y, line_height: 15,
      "text-anchor": "middle", "dominant-baseline": "middle", "font-family": "Arial, sans-serif",
      "font-size": "13", "font-weight": "700", "fill": "#1f2933"
    )
    lines << "  #{actor_text}"
  end

  lines << %(  <g fill="none" stroke="#4f5b67" stroke-width="1.4" marker-end="url(#arrow)">)
  feedback_index = 0
  flows.each do |flow|
    from_node = node_lookup.fetch(flow.fetch("from"))
    to_node = node_lookup.fetch(flow.fetch("to"))
    from_x, from_y = node_positions.fetch(from_node.fetch("id"))
    to_x, to_y = node_positions.fetch(to_node.fetch("id"))

    label = flow["label"].to_s.strip.downcase
    is_yes = from_node["type"] == "decision" && %w[si sí].include?(label)
    is_no = from_node["type"] == "decision" && label == "no"

    if is_no
      # La salida "No" abandona la decisión en vertical; después puede
      # continuar hacia su actividad sin competir con la salida "Sí" a la derecha.
      direction = to_y < from_y ? -1 : 1
      start = edge_anchor.call(from_node, direction.negative? ? :top : :bottom)
      finish = edge_anchor.call(to_node, :left)
      bend_x = start[0] + 28
      bend_y = start[1] + (direction * 14)
      approach_x = [bend_x + 20, finish[0] - 24].min
      points = [[start[0], start[1]], [start[0], bend_y], [approach_x, bend_y], [approach_x, finish[1]], [finish[0], finish[1]]]
    elsif is_yes || to_x >= from_x
      start = edge_anchor.call(from_node, :right)
      finish = edge_anchor.call(to_node, :left)
      mid_x = ((start[0] + finish[0]) / 2.0).round(2)
      points = [[start[0], start[1]], [mid_x, start[1]], [mid_x, finish[1]], [finish[0], finish[1]]]
    else
      start = edge_anchor.call(from_node, :left)
      finish = edge_anchor.call(to_node, :right)
      route_y = lane_bottom + 20 + (feedback_index * 24)
      feedback_index += 1
      # Los retornos usan una pista exclusiva bajo el proceso. Es una ruta
      # octolineal: vertical, horizontal y diagonal de 45 grados en los accesos.
      exit_x = start[0] - 18
      entry_x = finish[0] + 18
      points = [[start[0], start[1]], [exit_x, start[1]], [exit_x, route_y - 18], [exit_x - 18, route_y], [entry_x + 18, route_y], [entry_x, route_y - 18], [entry_x, finish[1]], [finish[0], finish[1]]]
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

  outputs = ["process-viewer.html", "process-overview.svg"]
  outputs.concat(view_phases(layout).map { |phase| "process-#{phase.fetch("id")}.svg" })
  outputs
end

def render_viewer_html(model)
  title = model.fetch("process").fetch("name")
  <<~HTML
    <!doctype html>
    <html lang="es">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{xml_escape(title)} - visor de diagrama</title>
      <style>
        :root {
          color-scheme: light;
          --bg: #f5f7fb;
          --panel: #ffffff;
          --border: #cad3df;
          --text: #1f2933;
          --muted: #52606d;
          --accent: #2563eb;
        }

        * {
          box-sizing: border-box;
        }

        html,
        body {
          width: 100%;
          height: 100%;
          margin: 0;
          overflow: hidden;
          font-family: Arial, sans-serif;
          color: var(--text);
          background: var(--bg);
        }

        .app {
          display: grid;
          grid-template-rows: auto 1fr;
          width: 100%;
          height: 100%;
        }

        .toolbar {
          display: flex;
          align-items: center;
          gap: 8px;
          min-height: 56px;
          padding: 10px 12px;
          border-bottom: 1px solid var(--border);
          background: var(--panel);
        }

        .title {
          min-width: 0;
          flex: 1;
          overflow: hidden;
          color: var(--muted);
          font-size: 14px;
          font-weight: 700;
          text-overflow: ellipsis;
          white-space: nowrap;
        }

        button {
          width: 36px;
          height: 36px;
          border: 1px solid var(--border);
          border-radius: 6px;
          color: var(--text);
          background: #fff;
          font-size: 18px;
          line-height: 1;
          cursor: pointer;
        }

        button:hover {
          border-color: var(--accent);
          color: var(--accent);
        }

        .zoom-value {
          width: 64px;
          color: var(--muted);
          font-size: 13px;
          font-variant-numeric: tabular-nums;
          text-align: center;
        }

        .viewport {
          position: relative;
          overflow: hidden;
          cursor: grab;
          background:
            linear-gradient(90deg, rgba(31, 41, 51, 0.05) 1px, transparent 1px),
            linear-gradient(rgba(31, 41, 51, 0.05) 1px, transparent 1px);
          background-size: 24px 24px;
        }

        .viewport.dragging {
          cursor: grabbing;
        }

        .canvas {
          position: absolute;
          top: 0;
          left: 0;
          transform-origin: 0 0;
          will-change: transform;
        }

        .diagram {
          display: block;
          max-width: none;
          user-select: none;
          -webkit-user-drag: none;
          box-shadow: 0 10px 28px rgba(31, 41, 51, 0.16);
          background: #fff;
        }
      </style>
    </head>
    <body>
      <main class="app">
        <div class="toolbar">
          <div class="title">#{xml_escape(title)}</div>
          <button type="button" data-action="zoom-out" aria-label="Reducir zoom" title="Reducir zoom">-</button>
          <div class="zoom-value" aria-live="polite">100%</div>
          <button type="button" data-action="zoom-in" aria-label="Aumentar zoom" title="Aumentar zoom">+</button>
          <button type="button" data-action="fit" aria-label="Ajustar a pantalla" title="Ajustar a pantalla">[]</button>
          <button type="button" data-action="reset" aria-label="Restablecer zoom" title="Restablecer zoom">1:1</button>
        </div>
        <div class="viewport">
          <div class="canvas">
            <img class="diagram" src="process.svg" alt="Diagrama completo de #{xml_escape(title)}">
          </div>
        </div>
      </main>
      <script>
        const viewport = document.querySelector(".viewport");
        const canvas = document.querySelector(".canvas");
        const diagram = document.querySelector(".diagram");
        const zoomValue = document.querySelector(".zoom-value");
        const minScale = 0.1;
        const maxScale = 4;
        let scale = 1;
        let offsetX = 24;
        let offsetY = 24;
        let dragging = false;
        let dragStartX = 0;
        let dragStartY = 0;
        let dragOffsetX = 0;
        let dragOffsetY = 0;

        function clamp(value, min, max) {
          return Math.min(max, Math.max(min, value));
        }

        function render() {
          canvas.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
          zoomValue.textContent = `${Math.round(scale * 100)}%`;
        }

        function zoomAt(nextScale, centerX, centerY) {
          const bounded = clamp(nextScale, minScale, maxScale);
          const diagramX = (centerX - offsetX) / scale;
          const diagramY = (centerY - offsetY) / scale;
          scale = bounded;
          offsetX = centerX - diagramX * scale;
          offsetY = centerY - diagramY * scale;
          render();
        }

        function fitToViewport() {
          const bounds = viewport.getBoundingClientRect();
          const widthScale = (bounds.width - 48) / diagram.naturalWidth;
          const heightScale = (bounds.height - 48) / diagram.naturalHeight;
          scale = clamp(Math.min(widthScale, heightScale), minScale, maxScale);
          offsetX = (bounds.width - diagram.naturalWidth * scale) / 2;
          offsetY = (bounds.height - diagram.naturalHeight * scale) / 2;
          render();
        }

        document.querySelector("[data-action='zoom-out']").addEventListener("click", () => {
          const bounds = viewport.getBoundingClientRect();
          zoomAt(scale / 1.2, bounds.width / 2, bounds.height / 2);
        });

        document.querySelector("[data-action='zoom-in']").addEventListener("click", () => {
          const bounds = viewport.getBoundingClientRect();
          zoomAt(scale * 1.2, bounds.width / 2, bounds.height / 2);
        });

        document.querySelector("[data-action='fit']").addEventListener("click", fitToViewport);

        document.querySelector("[data-action='reset']").addEventListener("click", () => {
          scale = 1;
          offsetX = 24;
          offsetY = 24;
          render();
        });

        viewport.addEventListener("wheel", (event) => {
          event.preventDefault();
          const bounds = viewport.getBoundingClientRect();
          const factor = event.deltaY < 0 ? 1.1 : 1 / 1.1;
          zoomAt(scale * factor, event.clientX - bounds.left, event.clientY - bounds.top);
        }, { passive: false });

        viewport.addEventListener("pointerdown", (event) => {
          dragging = true;
          dragStartX = event.clientX;
          dragStartY = event.clientY;
          dragOffsetX = offsetX;
          dragOffsetY = offsetY;
          viewport.classList.add("dragging");
          viewport.setPointerCapture(event.pointerId);
        });

        viewport.addEventListener("pointermove", (event) => {
          if (!dragging) return;
          offsetX = dragOffsetX + event.clientX - dragStartX;
          offsetY = dragOffsetY + event.clientY - dragStartY;
          render();
        });

        viewport.addEventListener("pointerup", (event) => {
          dragging = false;
          viewport.classList.remove("dragging");
          viewport.releasePointerCapture(event.pointerId);
        });

        diagram.addEventListener("load", fitToViewport);
        window.addEventListener("resize", fitToViewport);
        render();
      </script>
    </body>
    </html>
  HTML
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

  File.write(render_output_path(output_dir, "process-viewer.html"), render_viewer_html(model))

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
