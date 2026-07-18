# POC de modelos de procesos

Este repositorio prueba un flujo Docs as Code para mantener procesos a partir de un
modelo declarativo propio en YAML.

Cada proceso se documenta con estos artefactos:

```text
process.md
process.yaml
layout.yaml
process.puml
process.svg
metadata.yaml
```

La fuente de verdad del proceso es siempre `process.yaml`. El fichero `layout.yaml`
contiene solo preferencias de presentacion. `process.puml` y `process.svg` son
artefactos derivados y se regeneran con:

```bash
make diagrams
```

Para comprobar que el modelo es valido y que los artefactos derivados estan
actualizados:

```bash
make validate-diagrams
```

## Modelo fuente

El DSL del proceso es deliberadamente pequeno:

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
```

Tipos de nodo soportados:

```text
start
end
activity
decision
subprocess
event
document
note
```

Las swimlanes se deducen a partir de `actor`. El layout queda separado:

```yaml
direction: LR
lane-order:
  - requester
spacing: normal
```

La validacion comprueba, entre otras reglas:

- actores y nodos referenciados por los flujos
- ids duplicados
- un unico inicio y un unico fin
- actividades y decisiones con actor
- decisiones con al menos dos salidas etiquetadas
- actores sin actividad
- nodos no alcanzables desde el inicio
- nodos sin camino hasta el fin
- longitud maxima de etiquetas

## Estructura

```text
docs/processes/
  brief-to-epic/
    metadata.yaml
    process.md
    process.yaml
    layout.yaml
    process.puml
    process.svg
scripts/
  process-model.rb
  render-diagrams.sh
  validate-diagrams.sh
```

## Reglas de trabajo

- Modificar `process.yaml` cuando cambie la logica del proceso.
- Modificar `layout.yaml` solo cuando cambie la presentacion.
- Ejecutar `make diagrams` despues de cada cambio.
- Incluir en el commit `process.yaml`, `layout.yaml` y los derivados actualizados.
- No editar manualmente `process.puml` ni ficheros SVG.

## Renderizado

El script oficial genera primero PlantUML/DOT desde YAML y despues intenta
renderizar el SVG con estas opciones:

1. `plantuml`, si esta instalado.
2. JAR de PlantUML cacheado en `.cache/plantuml`, si hay Java runtime.
3. Servidor PlantUML via `PLANTUML_SERVER_URL`, si hay `python3` y `curl`.
4. Docker, si esta disponible.

La carpeta `.cache/` queda fuera de git.
