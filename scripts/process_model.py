#!/usr/bin/env python3
"""Valida modelos de proceso YAML y genera su diagrama SVG."""

from __future__ import annotations

import argparse
from collections import defaultdict, deque
from pathlib import Path
from xml.sax.saxutils import escape

import yaml

ALLOWED_NODE_TYPES = {"start", "end", "activity", "decision", "merge", "subprocess", "event", "document", "note"}
ACTOR_NODE_TYPES = {"activity", "decision", "merge", "subprocess", "event", "document"}
MAX_LABEL_LENGTH = 60


def load_model(path: Path) -> dict:
    try:
        with path.open(encoding="utf-8") as source:
            return yaml.safe_load(source) or {}
    except yaml.YAMLError as error:
        raise ValueError(f"{path}: invalid YAML: {error}") from error


def actor_id(actor: dict | str) -> str:
    return str(actor.get("id")) if isinstance(actor, dict) else str(actor)


def actor_label(actor: dict | str) -> str:
    if not isinstance(actor, dict):
        return str(actor)
    return str(actor.get("name", actor.get("label", actor.get("id"))))


def validate(model: dict, path: Path) -> None:
    errors: list[str] = []
    process, actors = model.get("process"), model.get("actors") or []
    nodes, flows = model.get("nodes") or [], model.get("flows") or []
    if not isinstance(process, dict) or not str(process.get("id", "")).strip(): errors.append("process.id is required")
    if not isinstance(process, dict) or not str(process.get("name", "")).strip(): errors.append("process.name is required")
    if not actors: errors.append("actors must not be empty")
    if not nodes: errors.append("nodes must not be empty")
    if not flows: errors.append("flows must not be empty")
    actor_ids = [actor_id(actor) for actor in actors]
    node_ids = [str(node.get("id", "")) for node in nodes]
    for ids, kind in ((actor_ids, "actor"), (node_ids, "node")):
        errors.extend(f"duplicated {kind} id: {item}" for item in set(ids) if ids.count(item) > 1)
    actor_lookup = dict(zip(actor_ids, map(actor_label, actors)))
    node_lookup = {str(node.get("id", "")): node for node in nodes}
    outgoing, incoming = defaultdict(list), defaultdict(list)
    for node in nodes:
        node_id, node_type = str(node.get("id", "")), str(node.get("type", ""))
        label = str(node.get("label", node_id))
        if not node_id: errors.append("node without id")
        if node_type not in ALLOWED_NODE_TYPES: errors.append(f"node {node_id}: unsupported type {node_type!r}")
        if len(label) > MAX_LABEL_LENGTH: errors.append(f"node {node_id}: label is too long (max {MAX_LABEL_LENGTH})")
        if node_type in ACTOR_NODE_TYPES:
            actor = str(node.get("actor", ""))
            if not actor: errors.append(f"node {node_id}: actor is required for {node_type}")
            elif actor not in actor_lookup: errors.append(f"node {node_id}: unknown actor {actor}")
    for flow in flows:
        source, target = str(flow.get("from", "")), str(flow.get("to", ""))
        if not source: errors.append("flow without from")
        if not target: errors.append("flow without to")
        if source not in node_lookup: errors.append(f"flow {source} -> {target}: source node does not exist")
        if target not in node_lookup: errors.append(f"flow {source} -> {target}: target node does not exist")
        if len(str(flow.get("label", ""))) > MAX_LABEL_LENGTH: errors.append(f"flow {source} -> {target}: label is too long (max {MAX_LABEL_LENGTH})")
        outgoing[source].append(flow); incoming[target].append(flow)
    starts = [node for node in nodes if node.get("type") == "start"]
    ends = [node for node in nodes if node.get("type") == "end"]
    if len(starts) != 1: errors.append("exactly one start node is required")
    if len(ends) != 1: errors.append("exactly one end node is required")
    for node in (node for node in nodes if node.get("type") == "decision"):
        node_id = str(node.get("id")); choices = outgoing[node_id]
        if not 2 <= len(choices) <= 4: errors.append(f"decision {node_id}: between two and four outgoing flows are required")
        if not str(node.get("label", "")).strip().endswith("?"): errors.append(f"decision {node_id}: a decision label must be a clear question")
        if len(incoming[node_id]) != 1: errors.append(f"decision {node_id}: a split must have exactly one incoming flow")
        labels = [str(flow.get("label", "")).strip().lower() for flow in choices]
        if any(not label for label in labels): errors.append(f"decision {node_id}: outgoing flows need labels")
        if len(labels) != len(set(labels)): errors.append(f"decision {node_id}: outgoing labels must be unique")
    for actor in set(actor_ids) - {node.get("actor") for node in nodes}: errors.append(f"actor {actor}: has no nodes")
    def reachable(seed: str, graph: dict, key: str) -> set[str]:
        found, queue = set(), deque([seed])
        while queue:
            current = queue.popleft()
            if current in found: continue
            found.add(current); queue.extend(str(flow.get(key, "")) for flow in graph[current])
        return found
    if len(starts) == 1:
        for item in set(node_ids) - reachable(str(starts[0]["id"]), outgoing, "to"): errors.append(f"node {item}: is not reachable from start")
    if len(ends) == 1:
        for item in set(node_ids) - reachable(str(ends[0]["id"]), incoming, "from"): errors.append(f"node {item}: cannot reach end")
    if errors: raise ValueError(f"{path} failed validation:\n- " + "\n- ".join(errors))


def wrap(label: str, width: int = 18) -> list[str]:
    lines, current = [], ""
    for word in label.split():
        candidate = f"{current} {word}".strip()
        if len(candidate) > width and current: lines.append(current); current = word
        else: current = candidate
    return lines + ([current] if current else [""])


def text(lines: list[str], x: float, y: float, size: int, weight: str = "400") -> str:
    spans = "".join(f'<tspan x="{x}" dy="{0 if i == 0 else 14}">{escape(line)}</tspan>' for i, line in enumerate(lines))
    offset = -7 * (len(lines) - 1)
    return f'<text x="{x}" y="{y + offset}" text-anchor="middle" font-family="Arial, sans-serif" font-size="{size}" font-weight="{weight}" fill="#1f2933">{spans}</text>'


def render(model: dict) -> str:
    layout, nodes, flows = model.get("layout", {}), model["nodes"], model["flows"]
    actors = {actor_id(actor): actor_label(actor) for actor in model["actors"]}
    lookup = {node["id"]: node for node in nodes}; outgoing = defaultdict(list); incoming = defaultdict(list)
    for flow in flows: outgoing[flow["from"]].append(flow); incoming[flow["to"]].append(flow)
    lane_order = [actor for actor in layout.get("lane-order", []) if actor in actors] + list(actors)
    lane_order = list(dict.fromkeys(lane_order))
    def lane(node: dict) -> str:
        if node.get("actor") in actors: return node["actor"]
        neighbours = outgoing[node["id"]] if node.get("type") == "start" else incoming[node["id"]]
        for flow in neighbours:
            neighbour = lookup[flow["to"] if node.get("type") == "start" else flow["from"]]
            if neighbour.get("actor") in actors: return neighbour["actor"]
        return lane_order[0]
    lanes = [actor for actor in lane_order if any(lane(node) == actor for node in nodes)]
    margin, title_h, actor_w, lane_h, column_w = 24, 56, 120, int(layout.get("lane-height", 116)), int(layout.get("column-width", 188))
    width = margin * 2 + actor_w + 88 + (len(nodes) - 1) * column_w + 142; height = margin * 2 + title_h + len(lanes) * lane_h + 72
    lane_index = {actor: i for i, actor in enumerate(lanes)}
    positions = {node["id"]: (margin + actor_w + 44 + i * column_w, margin + title_h + lane_index[lane(node)] * lane_h + lane_h / 2) for i, node in enumerate(nodes)}
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">', f'<title id="title">{escape(str(model["process"]["name"]))}</title>', '<desc id="desc">Diagrama generado desde process.yaml.</desc>', '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M 0 0 L 10 5 L 0 10 z" fill="#4f5b67"/></marker></defs>', f'<rect x="{margin}" y="{margin}" width="{width-margin*2}" height="{height-margin*2}" fill="#fff" stroke="#4f5b67"/>', text([str(model["process"]["name"])], width / 2, margin + 32, 20, "700")]
    for index, actor in enumerate(lanes):
        y = margin + title_h + index * lane_h; fill = "#f8fafc" if index % 2 == 0 else "#eef4ff"
        lines += [f'<rect x="{margin}" y="{y}" width="{width-margin*2}" height="{lane_h}" fill="{fill}" stroke="#d5dce6"/>', f'<rect x="{margin}" y="{y}" width="{actor_w}" height="{lane_h}" fill="#e6edf7" stroke="#d5dce6"/>', text(wrap(actors[actor], 16), margin + actor_w / 2, y + lane_h / 2, 13, "700")]
    lines.append('<g fill="none" stroke="#4f5b67" stroke-width="1.4" marker-end="url(#arrow)">')
    for flow in flows:
        sx, sy = positions[flow["from"]]; tx, ty = positions[flow["to"]]; direction = 1 if tx >= sx else -1
        lines.append(f'<polyline points="{sx + direction*71},{sy} {(sx+tx)/2},{sy} {(sx+tx)/2},{ty} {tx-direction*71},{ty}"/>')
    lines.append('</g>')
    for flow in flows:
        if flow.get("label"):
            sx, sy = positions[flow["from"]]; tx, ty = positions[flow["to"]]
            lines.append(text([str(flow["label"])], (sx + tx) / 2, (sy + ty) / 2 - 8, 11))
    for node in nodes:
        x, y = positions[node["id"]]; kind, label = node["type"], str(node.get("label", node["id"]))
        if kind == "start": lines.append(f'<circle cx="{x}" cy="{y}" r="15" fill="#1f2933"/>')
        elif kind == "end": lines.append(f'<circle cx="{x}" cy="{y}" r="15" fill="#fff" stroke="#1f2933" stroke-width="2"/><circle cx="{x}" cy="{y}" r="10" fill="#1f2933"/>')
        elif kind in {"decision", "merge"}: lines.append(f'<polygon points="{x},{y-36} {x+62},{y} {x},{y+36} {x-62},{y}" fill="#fff" stroke="#4f5b67" stroke-width="1.5"/>'); lines.append(text(wrap(label, 15), x, y, 11)) if kind == "decision" else None
        else: lines.append(f'<rect x="{x-71}" y="{y-26}" width="142" height="52" rx="4" fill="#fff" stroke="#4f5b67" stroke-width="1.5"/>'); lines.append(text(wrap(label), x, y, 12))
    return "\n".join(lines + ["</svg>", ""])


def main() -> None:
    parser = argparse.ArgumentParser(); parser.add_argument("command", choices=["validate", "render-svg"]); parser.add_argument("process_path", type=Path); parser.add_argument("output_path", type=Path, nargs="?"); args = parser.parse_args()
    model = load_model(args.process_path); validate(model, args.process_path)
    if args.command == "validate": print(f"{args.process_path}: ok")
    else:
        if args.output_path is None: parser.error("render-svg requires output-path")
        args.output_path.write_text(render(model), encoding="utf-8")


if __name__ == "__main__": main()
