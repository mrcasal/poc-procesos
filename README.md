# POC de documentación de procesos

Esta POC mantiene los procesos como documentación versionable en el repositorio,
sin publicación ni dependencia de GitHub Pages.

Cada proceso se compone de:

```text
process.md    Documento de lectura del proceso
process.yaml  Fuente de verdad: lógica y preferencias de renderizado
process.svg   Diagrama completo renderizado desde el YAML
```

## Lectura e impresión

`process.md` es el documento de proceso que se consulta en el repositorio o en
cualquier visor Markdown compatible. Los diagramas SVG se muestran incrustados
en ese documento.

Cada documento incluye un enlace al SVG completo. Al abrirlo directamente se
puede ampliar y usar la impresión del navegador o del sistema, conservando la
calidad vectorial a un tamaño mayor que el mostrado en el Markdown.

## Actualización

La lógica del proceso y sus preferencias de presentación viven juntas en
`process.yaml`; el SVG no se edita manualmente.

La POC usa Python 3 y la dependencia declarada en `requirements.txt`:

```bash
python -m pip install -r requirements.txt
```

```bash
make diagrams
make validate-diagrams
```

`make diagrams` regenera el SVG completo. `make validate-diagrams` valida el
modelo y confirma que el SVG no está desactualizado.

## Modelo fuente

El DSL es deliberadamente pequeño:

```yaml
process:
  id: AGU-001
  name: Gestion de Brief

actors:
  - id: requester
    name: Solicitante

nodes:
  - id: start
    type: start
  - id: create_brief
    actor: requester
    type: activity
    label: Preparar brief
  - id: end
    type: end

flows:
  - from: start
    to: create_brief
  - from: create_brief
    to: end

layout:
  direction: LR
  lane-order:
    - requester
```

Tipos de nodo soportados:

```text
start, end, activity, decision, merge, subprocess, event, document, note
```

Las swimlanes se deducen del actor del nodo.

## Estructura

```text
docs/processes/
  nombre-del-proceso/
    process.md
    process.yaml
    process.svg
scripts/
  process_model.py
  render-diagrams.sh
  validate-diagrams.sh
```

## Reglas de trabajo

- Modificar `process.md` cuando cambie la explicación, reglas o contexto.
- Modificar `process.yaml` cuando cambie la lógica o la presentación del diagrama.
- Ejecutar `make diagrams` después de cambiar el YAML.
- Ejecutar `make validate-diagrams` antes de integrar los cambios.
- Incluir el Markdown, el YAML y el SVG generado en el commit.
- No editar manualmente los SVG.
