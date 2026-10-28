# TechConecta SV – MVP (guía de montaje)

Estructura:
```
techconecta-sv/
├── supabase/schema.sql          # tablas, triggers, función de búsqueda y RLS
├── api/                         # API REST Node.js + Express
├── web/index.html               # Frontend mínimo (cliente y técnico)
├── deploy/nginx.conf            # frontend en / y proxy /api -> :3000
└── .github/workflows/deploy.yml # CI/CD a EC2
```

## 1. Supabase (15 min)
1. Crea un proyecto en https://supabase.com.
2. SQL Editor → New query → pega `supabase/schema.sql` → Run.
3. Authentication → Providers → Email: para pruebas, desactiva "Confirm email".
4. Project Settings → API: copia **Project URL** y **anon public key**.

## 2. API en local (VS Code)
```bash
cd api
cp .env.example .env     # pega URL y anon key
npm install
npm run dev
```
Prueba con Postman / Thunder Client:
1. `POST /auth/register` `{"email":"cli@test.com","password":"Test1234!","nombre":"Ana","rol":"cliente"}`
2. `POST /auth/register` `{"email":"tec@test.com","password":"Test1234!","nombre":"Luis","rol":"tecnico","especialidad":"electricista"}`
3. `POST /auth/login` → copia `access_token` (úsalo como `Authorization: Bearer <token>`).
4. Login como técnico → `PATCH /tecnicos/me` `{"latitud":13.69,"longitud":-89.19,"tarifa_hora":15}`.
5. Login como cliente → `GET /tecnicos?lat=13.69&lng=-89.19&especialidad=electricista`.
6. `POST /solicitudes` `{"especialidad":"electricista","descripcion":"Sin luz","latitud":13.69,"longitud":-89.19}`.
7. Técnico: `GET /solicitudes` → `PATCH /solicitudes/:id/aceptar` → `PATCH /solicitudes/:id/completar` `{"costo":25}`.
8. Cliente: `POST /resenas` `{"solicitud_id":"...","calificacion":5,"comentario":"Excelente"}`.
9. Prueba de RLS: con un segundo cliente, intenta `PATCH /solicitudes/:id/cancelar` de la solicitud del primero → debe fallar (evidencia para el informe).

### Probar el frontend en local
Con la API corriendo (`npm run dev`), abre `web/index.html` con la extensión **Live Server** de VS Code (clic derecho → Open with Live Server). Detecta `localhost` y usa `http://localhost:3000`. Registra un técnico y un cliente en dos ventanas (una normal y una de incógnito) para ver el flujo completo.

### Foto de perfil del técnico (Supabase Storage)

La aplicación permite que un técnico suba una foto JPG, PNG o WebP de hasta 5 MB. El bucket privado `fotos-perfil` lo administra Supabase Storage; no se necesita AWS S3, IAM ni una tabla adicional. La API usa el JWT del usuario para aplicar las políticas RLS de `storage.objects` y genera URLs firmadas de corta duración.

Ejecuta el esquema completo de [supabase/schema.sql](supabase/schema.sql). También puedes crear el bucket desde **Supabase → Storage → New bucket**, con estas opciones:

1. Nombre: `fotos-perfil`.
2. Bucket público: desactivado.
3. Límite: 5 MB.
4. Tipos permitidos: `image/jpeg`, `image/png`, `image/webp`.

El SQL deja configurado el bucket y sus políticas. Agrega al `.env` de la API:

> Ejecuta este esquema en un proyecto nuevo o como una migración controlada. Si ya lo ejecutaste antes, no lo pegues por segunda vez sin revisar los objetos existentes, porque los tipos, tablas, triggers y políticas tienen nombres fijos.

```env
SUPABASE_STORAGE_BUCKET=fotos-perfil
SUPABASE_URL_EXPIRY_SECONDS=300
```

No agregues credenciales de servicio al frontend ni al repositorio. La clave `SUPABASE_ANON_KEY` se usa en la API junto con el JWT del usuario; Storage aplica las políticas de acceso por usuario.

## 3. GitHub
```bash
git init && git add . && git commit -m "MVP TechConecta"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/techconecta-sv.git
git push -u origin main
```
(El primer push disparará el workflow y fallará hasta configurar los secrets del paso 5: es normal.)

## 4. AWS
1. **VPC**: usa "VPC and more" (10.0.0.0/16, 2 AZ, 2 subredes públicas, sin NAT gateway para no pagar).
2. **Security Group**: entrada 80 (0.0.0.0/0), 443 (0.0.0.0/0), 22 (solo *My IP*).
3. **EC2**: Ubuntu 24.04, t3.micro, en subred pública, IP pública activada, key pair nuevo (.pem).
   Opcional: Elastic IP para que la IP no cambie al reiniciar.
4. Conéctate: `ssh -i tu-llave.pem ubuntu@IP_PUBLICA` e instala:
```bash
sudo apt update && sudo apt install -y nginx rsync
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs
sudo npm install -g pm2
mkdir -p ~/techconecta-api
sudo mkdir -p /var/www/techconecta && sudo chown $USER:$USER /var/www/techconecta
```
5. Crea `~/techconecta-api/.env` en el servidor con `PORT=3000`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_STORAGE_BUCKET` y `SUPABASE_URL_EXPIRY_SECONDS`
   (el workflow no lo sobrescribe).
6. Nginx:
```bash
sudo nano /etc/nginx/sites-available/techconecta     # pega deploy/nginx.conf
sudo ln -s /etc/nginx/sites-available/techconecta /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```
7. Primer despliegue manual (desde tu PC): 
   `rsync -az -e "ssh -i tu-llave.pem" --exclude node_modules --exclude .env api/ ubuntu@IP:~/techconecta-api/`
   y en el servidor: `cd ~/techconecta-api && npm ci --omit=dev && pm2 start src/index.js --name techconecta-api && pm2 save && pm2 startup`
8. Copia el frontend: `rsync -az -e "ssh -i tu-llave.pem" web/ ubuntu@IP:/var/www/techconecta/`
9. Verifica: `http://IP_PUBLICA/` (la web) y `http://IP_PUBLICA/api/health` (la API).

**HTTPS (puerto 443):** necesita un dominio. Con dominio apuntando a la IP: `sudo apt install certbot python3-certbot-nginx && sudo certbot --nginx`. Sin dominio, indica en el informe que HTTPS se activa al asignar dominio (Route 53 + ACM/Let's Encrypt).

## 5. GitHub Actions (CI/CD)
Repo → Settings → Secrets and variables → Actions → New secret:
- `EC2_HOST`: IP pública de la EC2
- `EC2_USER`: `ubuntu`
- `EC2_SSH_KEY`: contenido completo del archivo .pem

Haz un cambio pequeño, `git push` y mira la pestaña **Actions**. Captura el despliegue exitoso.

## 6. CloudWatch
- EC2 → Monitoring: CPU y red ya aparecen sin configurar nada.
- Alarma: CloudWatch → Alarms → Create → métrica `EC2 > Per-Instance > CPUUtilization` → umbral > 80% → notificación por correo (SNS).
- Memoria: instala el CloudWatch Agent (rol IAM `CloudWatchAgentServerPolicy` en la EC2) si necesitas esa métrica.
- Latencia: mide con `curl -w "%{time_total}\n" -o /dev/null -s http://IP/api/health`.

## 7. Costos / limpieza
- Crea un presupuesto de alerta (Billing → Budgets, $5).
- Al terminar las evidencias: detén o termina la EC2 y libera la Elastic IP.
- Nunca subas `.env` ni el `.pem` a GitHub.

## Evidencias sugeridas para el informe
Tablas en Supabase, políticas RLS, pruebas Postman, VPC/SG, EC2 corriendo, `/health` desde navegador,
workflow verde en Actions, gráfica y alarma de CloudWatch.
