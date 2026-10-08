# Encuesta de servicio · Aquamare Hotel (PWA)

Archivos: `index.html` (toda la app en React), `manifest.json`, `sw.js`, iconos, `aqua.png` (logo), `supabase.sql`.

## 1. Supabase
1. Crea un proyecto en supabase.com.
2. SQL Editor → pega y ejecuta `supabase.sql`.
3. Project Settings → API: copia **Project URL** y **anon public key**.
4. En `index.html`, pégalos en `CONFIG` (arriba del bloque de script).

## 2. GitHub Pages
1. Sube todos los archivos de esta carpeta a un repo (raíz).
2. Settings → Pages → Branch `main` / root.
3. Tu URL será `https://USUARIO.github.io/REPO/`.
4. Entra a `#/admin` → Ajustes → pega esa URL en "URL pública" **antes** de imprimir QR/TAG.

## 3. Uso
- Admin: `https://USUARIO.github.io/REPO/#/admin`
- Cliente: el QR/TAG abre `…/?m=CODIGO` y la encuesta queda ligada a ese mesero con fecha y hora del servidor.
- NFC: el botón "Asignar TAG NFC" graba la URL en el TAG solo desde **Android + Chrome** (HTTPS). En iPhone/PC usa la app gratuita "NFC Tools" para grabar la URL (botón "Copiar URL del TAG").
- Reseña Google: en Ajustes pega el Place ID (o el enlace de reseña). El cliente debe tener sesión de Google en su celular; Google no permite publicar reseñas sin cuenta ni por API.

## Seguridad
El admin no tiene login (como pediste), así que **cualquiera que conozca la URL `#/admin` y use la anon key puede ver/editar datos**, incluidas las cédulas. No publiques ni compartas el enlace del admin.
