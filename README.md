# POC de diagramas de procesos

Este repositorio prueba un flujo sencillo para mantener diagramas de procesos con PlantUML.

Cada proceso se documenta con estos artefactos:

```text
process.md
process.puml
process.svg
metadata.yaml
```

La fuente de verdad del diagrama es siempre `process.puml`. El SVG es un artefacto derivado y se regenera con:

```bash
make diagrams
```

Para comprobar que los SVG estan actualizados:

```bash
make validate-diagrams
```

## Estructura

```text
docs/processes/
  brief-to-epic/
    metadata.yaml
    process.md
    process.puml
    process.svg
scripts/
  render-diagrams.sh
  validate-diagrams.sh
```

## Reglas de trabajo

- Modificar solo `process.puml` cuando cambie el diagrama.
- Ejecutar `make diagrams` despues de cada cambio.
- Incluir en el commit el par `process.puml` y `process.svg`.
- No editar manualmente ficheros SVG.

## Renderizado

El script oficial intenta renderizar con estas opciones:

1. `plantuml`, si esta instalado.
2. JAR de PlantUML cacheado en `.cache/plantuml`, si hay Java runtime.
3. Servidor PlantUML via `PLANTUML_SERVER_URL`, si hay `python3` y `curl`.
4. Docker, si esta disponible.

La carpeta `.cache/` queda fuera de git.
