import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { createClient } from '@supabase/supabase-js';

const { SUPABASE_URL, SUPABASE_ANON_KEY, PORT = 3000 } = process.env;
if (!SUPABASE_URL || !SUPABASE_ANON_KEY) {
  console.error('Faltan SUPABASE_URL o SUPABASE_ANON_KEY en .env');
  process.exit(1);
}

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json());

// Cliente anónimo (registro / login)
const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Middleware: valida el JWT y crea un cliente "con la identidad del usuario",
// así las políticas RLS de Supabase se aplican a cada consulta.
async function auth(req, res, next) {
  const token = (req.headers.authorization || '').replace('Bearer ', '');
  if (!token) return res.status(401).json({ error: 'Token requerido' });
  const { data, error } = await anon.auth.getUser(token);
  if (error || !data.user) return res.status(401).json({ error: 'Token inválido' });
  req.user = data.user;
  req.db = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  next();
}

const fail = (res, error, code = 400) => res.status(code).json({ error: error.message || error });

// ---------- Salud (para pruebas de latencia y monitoreo) ----------
app.get('/health', (_req, res) => res.json({ status: 'ok', time: new Date().toISOString() }));

// ---------- Autenticación ----------
app.post('/auth/register', async (req, res) => {
  const { email, password, nombre, telefono, rol = 'cliente', especialidad } = req.body;
  if (!email || !password || !nombre) return fail(res, 'email, password y nombre son obligatorios');
  if (!['cliente', 'tecnico'].includes(rol)) return fail(res, 'rol inválido');
  if (rol === 'tecnico' && !especialidad) return fail(res, 'el técnico requiere especialidad');
  const { data, error } = await anon.auth.signUp({
    email, password, options: { data: { nombre, telefono, rol, especialidad } },
  });
  if (error) return fail(res, error);
  res.status(201).json({ id: data.user?.id, email });
});

app.post('/auth/login', async (req, res) => {
  const { email, password } = req.body;
  const { data, error } = await anon.auth.signInWithPassword({ email, password });
  if (error) return fail(res, error, 401);
  res.json({ access_token: data.session.access_token, user_id: data.user.id });
});

// ---------- Perfil propio ----------
app.get('/me', auth, async (req, res) => {
  const { data, error } = await req.db.from('perfiles')
    .select('id, nombre, telefono, rol, tecnicos(*)').eq('id', req.user.id).single();
  if (error) return fail(res, error);
  res.json(data);
});

// ---------- Técnicos ----------
// GET /tecnicos?lat=13.69&lng=-89.19&especialidad=electricista&radio_km=5
app.get('/tecnicos', auth, async (req, res) => {
  const { lat, lng, especialidad = null, radio_km = 5 } = req.query;
  if (lat === undefined || lng === undefined) return fail(res, 'lat y lng son obligatorios');
  const { data, error } = await req.db.rpc('buscar_tecnicos', {
    p_lat: Number(lat), p_lng: Number(lng),
    p_especialidad: especialidad, p_radio_km: Number(radio_km),
  });
  if (error) return fail(res, error);
  res.json(data);
});

// El técnico actualiza su ubicación / disponibilidad
app.patch('/tecnicos/me', auth, async (req, res) => {
  const { latitud, longitud, disponible, tarifa_hora, zona } = req.body;
  const cambios = Object.fromEntries(
    Object.entries({ latitud, longitud, disponible, tarifa_hora, zona }).filter(([, v]) => v !== undefined));
  const { data, error } = await req.db.from('tecnicos').update(cambios).eq('id', req.user.id).select().single();
  if (error) return fail(res, error);
  res.json(data);
});

// ---------- Solicitudes ----------
app.post('/solicitudes', auth, async (req, res) => {
  const { especialidad, descripcion, latitud, longitud } = req.body;
  if (!especialidad) return fail(res, 'especialidad es obligatoria');
  const { data, error } = await req.db.from('solicitudes')
    .insert({ cliente_id: req.user.id, especialidad, descripcion, latitud, longitud })
    .select().single();
  if (error) return fail(res, error);
  res.status(201).json(data);
});

// Solicitudes propias (cliente o técnico asignado) y pendientes de mi especialidad (técnico)
app.get('/solicitudes', auth, async (req, res) => {
  const { data, error } = await req.db.from('solicitudes').select('*').order('creado_en', { ascending: false });
  if (error) return fail(res, error);
  res.json(data);
});

// El técnico acepta: solo si sigue pendiente (evita que dos técnicos acepten la misma)
app.patch('/solicitudes/:id/aceptar', auth, async (req, res) => {
  const { data, error } = await req.db.from('solicitudes')
    .update({ tecnico_id: req.user.id, estado: 'aceptada' })
    .eq('id', req.params.id).eq('estado', 'pendiente').select();
  if (error) return fail(res, error);
  if (!data.length) return fail(res, 'La solicitud ya no está disponible', 409);
  res.json(data[0]);
});

app.patch('/solicitudes/:id/completar', auth, async (req, res) => {
  const { costo } = req.body;
  const { data, error } = await req.db.from('solicitudes')
    .update({ estado: 'completada', costo })
    .eq('id', req.params.id).eq('tecnico_id', req.user.id).eq('estado', 'aceptada').select();
  if (error) return fail(res, error);
  if (!data.length) return fail(res, 'No se pudo completar la solicitud', 409);
  res.json(data[0]);
});

app.patch('/solicitudes/:id/cancelar', auth, async (req, res) => {
  const { data, error } = await req.db.from('solicitudes')
    .update({ estado: 'cancelada' })
    .eq('id', req.params.id).eq('cliente_id', req.user.id).in('estado', ['pendiente', 'aceptada']).select();
  if (error) return fail(res, error);
  if (!data.length) return fail(res, 'No se pudo cancelar', 409);
  res.json(data[0]);
});

// ---------- Reseñas ----------
app.post('/resenas', auth, async (req, res) => {
  const { solicitud_id, calificacion, comentario } = req.body;
  const { data: sol, error: e1 } = await req.db.from('solicitudes')
    .select('tecnico_id').eq('id', solicitud_id).single();
  if (e1 || !sol?.tecnico_id) return fail(res, 'Solicitud no encontrada o sin técnico', 404);
  const { data, error } = await req.db.from('resenas')
    .insert({ solicitud_id, cliente_id: req.user.id, tecnico_id: sol.tecnico_id, calificacion, comentario })
    .select().single();
  if (error) return fail(res, error);
  res.status(201).json(data);
});

app.listen(PORT, () => console.log(`TechConecta API escuchando en puerto ${PORT}`));
