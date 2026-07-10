# Despliegue — PMS Hotel Monasterio

El sistema son dos partes: **backend** (Supabase, en la nube) y **frontend**
(esta app React, hosteada como sitio estático).

## Variables de entorno del frontend

Vite expone al navegador solo las que empiezan con `VITE_`. Se necesitan dos:

| Variable | Dónde sacarla | ¿Secreta? |
|---|---|---|
| `VITE_SUPABASE_URL` | Supabase → Project Settings → API → Project URL | No |
| `VITE_SUPABASE_ANON_KEY` | Supabase → Project Settings → API → `anon public` | No (pública por diseño; la RLS protege los datos) |

> NUNCA subas la `service_role` al frontend.

En desarrollo van en `.env.local` (ignorado por git). En producción se cargan en
el panel del host (Netlify / Amplify).

## 1. Backend (Supabase)

```bash
npx supabase db push          # aplica TODAS las migraciones pendientes
```

Luego, en el dashboard de Supabase:
- **Authentication → URL Configuration**: agregá el dominio de producción en
  *Site URL* y *Redirect URLs*.
- Verificá que existan los **buckets de storage**: `avatars` (público),
  `receipts` y `login-bg`/assets (según corresponda). Los crean las migraciones.

## 2. Frontend

El build genera archivos estáticos en `dist/`. Las variables `VITE_*` se
"hornean" en el build.

### Opción A — Netlify (con GitHub)
1. Netlify → *Add new site* → *Import from Git* → elegí el repo.
2. Build command: `npm run build` · Publish directory: `dist` (ya están en
   `netlify.toml`).
3. *Site settings → Environment variables*: cargá `VITE_SUPABASE_URL` y
   `VITE_SUPABASE_ANON_KEY`.
4. Deploy. Cada `git push` re-despliega solo.

### Opción B — AWS Amplify (con GitHub)
1. Amplify → *New app* → *Host web app* → conectá el repo y la rama.
2. Amplify detecta `amplify.yml` (build command + `dist`).
3. *Environment variables*: cargá `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY`.
4. *Rewrites and redirects*: agregá `200` de `/<*>` a `/index.html` (SPA).
5. Deploy.

### Opción C — Rápida sin CI (Netlify Drop / Cloudflare Pages)
```bash
npm run build
```
Arrastrá la carpeta `dist/` al drop del host. Las variables ya quedan incluidas
en el build local (desde `.env.local`).

## Checklist v1.0
- [ ] Migraciones aplicadas (`supabase db push`)
- [ ] Site/Redirect URL configuradas en Supabase Auth
- [ ] Variables `VITE_*` cargadas en el host
- [ ] Frontend desplegado
- [ ] Usuario `root` creado en producción
- [ ] Dominio propio + HTTPS (lo dan los hosts)
