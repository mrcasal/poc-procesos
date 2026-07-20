# POC de modelos de procesos

Este repositorio prueba un flujo Docs as Code para mantener procesos a partir de un
modelo declarativo propio en YAML.

Cada proceso se documenta con estos artefactos:

```text
process.md
process.yaml
layout.yaml
process.svg
metadata.yaml
```

Los procesos largos pueden generar tambien vistas derivadas para lectura en
documento:

```text
process-overview.svg
process-<fase>.svg
process-viewer.html
```

La fuente de verdad del proceso es siempre `process.yaml`. El fichero `layout.yaml`
contiene solo preferencias de presentacion. Tambien puede declarar fases visuales
para producir una vista general y diagramas parciales sin dividir el modelo fuente.
`process.svg`, las vistas derivadas y el visor HTML son artefactos generados y se
regeneran con:

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
views:
  phases:
    - id: fase-0-recepcion
      label: "Fase 0: Recepcion"
      nodes:
        - create_brief
```

## Normas de diagramado

El SVG oficial se genera directamente desde `process.yaml` y aplica siempre la
misma plantilla visual:

- una caja exterior recoge todo el proceso
- el proceso se divide en lanes horizontales, una por actor
- el nombre del actor aparece en la parte izquierda de su lane
- el nombre del actor se muestra horizontalmente y se parte en varias líneas cuando sea necesario; nunca se recorta
- el proceso comienza a la izquierda y avanza hacia la derecha; los cambios de lane se resuelven de arriba hacia abajo
- inicio, fin, actividades y decisiones mantienen tamanos fijos
- la salida `Sí` de una decisión continúa siempre hacia adelante y a la derecha
- la salida `No` de una decisión sale en vertical, hacia arriba o abajo según la posición de su destino
- las flechas usan conectores octolineales: tramos rectos horizontales, verticales y diagonales de 45 grados; los retornos se enrutan por pistas separadas para evitar cruces

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
- Incluir en el commit `process.yaml`, `layout.yaml` y el SVG actualizado.
- No editar manualmente ficheros SVG.

## Renderizado

El script oficial genera `process.svg` directamente desde YAML usando
`scripts/process-model.rb`. No usa renderizadores externos ni formatos
intermedios.
