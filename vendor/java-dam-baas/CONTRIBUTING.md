# Gitworkflow

| Rama | Descripción | Origen | Destino (Merge) |
| --- | --- | --- | --- |
| **`main`** | Código 100% funcional y listo para presentar. Intocable. | - | - |
| **`develop`** | Rama de integración. Aquí se junta todo. | `main` | - |
| **`feature/...`** | Para nuevas funcionalidades. | `develop` | `develop` |
| **`fix/...`** | Para corregir errores detectados en desarrollo. | `develop` | `develop` |
| **`hotfix/...`** | Para errores críticos en la demo final. | `main` | `main` y `develop` |

**Ejemplo:**

* `feature/login-screen`
* `feature/reserva-service`
* `fix/validacion-dni`

## B. Estructura de Commits (Conventional Commits)

Cada commit debe seguir este formato para que el historial sea legible y profesional:

`tipo(alcance): descripción breve`

**Tipos permitidos:**

* `feat`: Una nueva funcionalidad (ej. añadir login).
* `fix`: Solución de un bug.
* `docs`: Cambios solo en documentación.
* `style`: Cambios de formato (espacios, puntos y coma) que no afectan lógica.
* `refactor`: Cambio de código que no arregla bugs ni añade funcionalidades (limpieza).
* `test`: Añadir o corregir tests.
* `chore`: Tareas de mantenimiento (actualizar dependencias, configurar .gitignore).

**Ejemplos:**

1. *Creando la entidad Usuario:*
```text
feat(backend): create Usuario entity with JPA annotations

```

2. *Arreglando un fallo en el calendario:*
```text
fix(frontend): resolve date overlap issue in calendar view

```

3. *Actualizando el README:*
```text
docs: update project setup instructions in README

```

4. *Cerrando un issue automáticamente:*
```text
feat(auth): implement login service logic

Closes #15

```
