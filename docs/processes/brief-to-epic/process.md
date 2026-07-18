# Generacion de epica desde brief

Este proceso ilustra la conversion de un brief inicial en una epica lista para priorizar.

## Artefactos

- Modelo fuente: `process.yaml`
- Preferencias de layout: `layout.yaml`
- PlantUML generado: `process.puml`
- SVG renderizado: `process.svg`
- Metadatos: `metadata.yaml`

## Actualizacion

1. Modificar `process.yaml` si cambia la logica del proceso.
2. Modificar `layout.yaml` si cambia solo la presentacion.
3. Ejecutar `make diagrams`.
4. Verificar con `make validate-diagrams`.
5. Incluir modelo, layout y derivados en el commit.
