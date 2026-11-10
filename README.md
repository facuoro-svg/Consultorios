# Consultorios

Gestión de consultorios para profesionales de la salud: agenda, alquileres, cobros, socios y portal para profesionales.

## Cómo está armado
- `index.html`: la app completa (sitio estático). Se publica en Vercel tal cual, sin build.
- `supabase/01_esquema.sql`: base de datos, permisos por fila y funciones (reservar, cancelar, agenda anónima). Se pega en Supabase › SQL Editor.
- `prototipo/consultorios.html` + `scripts/construir.py`: la app se genera desde el prototipo probado:
  `python3 scripts/construir.py prototipo/consultorios.html`

## Accesos
- El primer mail que entra queda como **dueño**.
- Un **profesional** entra con el mail cargado en su ficha y ve solo lo suyo.
- Otros dueños o socios se suman desde Más › Ajustes › Accesos.
