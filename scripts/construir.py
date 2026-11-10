"""Arma index.html (app real con Supabase) a partir del prototipo probado.

Uso: python3 scripts/construir.py ruta/al/prototipo.html
"""
import sys

src = sys.argv[1]
s = open(src, encoding="utf-8").read()


def rep(a, b, n=1):
    global s
    assert s.count(a) == n, (s.count(a), a[:120])
    s = s.replace(a, b)


SB_URL = "https://embskyeirpogtjpywcjr.supabase.co"
SB_KEY = "sb_publishable_vp9Lj_sD3agOysDPdPTxtQ_a1nLjkTD"

# ---------- cabecera: documento completo + supabase-js ----------
rep('<title>Mis Consultorios</title>\n<meta name="claude:viewport-fit-sides" content="cover">',
    '<!doctype html>\n<html lang="es">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">\n'
    '<title>Mis Consultorios</title>\n<meta name="theme-color" content="#111418">\n'
    '<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js"></script>')
rep('</style>\n\n<div class="app">', '''/* Login */
.login { min-height: 100dvh; display: grid; place-items: center; padding: 24px max(16px, env(safe-area-inset-right, 0px)) 24px max(16px, env(safe-area-inset-left, 0px)); }
.login-card { width: 100%; max-width: 380px; display: flex; flex-direction: column; gap: 16px; background: var(--surface); border: 1px solid var(--line); border-radius: 16px; padding: 24px; box-shadow: var(--shadow); }
.login-card h1 { margin: 0; font-size: 1.4rem; }
html, body { margin: 0; background: var(--bg); color: var(--fg); }
[hidden] { display: none !important; }
</style>
</head>
<body>
<div id="loginRoot" hidden></div>
<div class="app" id="appRoot">''')
rep('<div class="side-foot"><span id="syncState">Conectando…</span></div>',
    '<div class="side-foot"><span id="syncState">Conectando…</span><span id="userMail" class="small"></span><button type="button" class="btn ghost sm" style="align-self:flex-start;padding:0" data-a="salir">Cerrar sesión</button></div>')
assert s.rstrip().endswith('</script>'), s[-200:]
s = s.rstrip() + '\n</body>\n</html>\n'

# ---------- capa de datos ----------
rep('let db = null, downloads = null, modoLocal = false, listo = false;',
    'const SB = window.supabase.createClient("' + SB_URL + '", "' + SB_KEY + '");\n'
    'let modoLocal = false, listo = false, ROL = null, MI_PROF = null, MI_MAIL = "";')

rep('''async function put(col, id, data) {
  const body = { ...data }; delete body.id;
  D[col][id] = { id, ...body }; pedirRender();
  if (modoLocal) { guardarLocal(); return true; }
  try { await db.collection(col).doc(id).set(body); return true; }
  catch (e) { toast(e && e.code === "quota_exceeded" ? "Se llenó el espacio de datos. Borrá registros viejos." : "No se pudo guardar. Revisá la conexión y probá de nuevo."); return false; }
}
async function del(col, id) {
  delete D[col][id]; pedirRender();
  if (modoLocal) { guardarLocal(); return true; }
  try { await db.collection(col).doc(id).delete(); return true; } catch (e) { toast("No se pudo borrar. Probá de nuevo."); return false; }
}
async function putConfig(data) {
  D.config = { ...D.config, ...data }; pedirRender();
  if (modoLocal) { guardarLocal(); return; }
  try { await db.doc("config/main").set(D.config); } catch (e) { toast("No se pudo guardar la configuración."); }
}''', '''async function put(col, id, data) {
  const body = { ...data }; delete body.id;
  D[col][id] = { id, ...body }; pedirRender();
  const q = ROL === "profesional" ? SB.from("docs").insert({ col, id, data: body }) : SB.from("docs").upsert({ col, id, data: body, updated_at: new Date().toISOString() });
  const { error } = await q;
  if (error) { console.error(error); toast("No se pudo guardar. Revisá la conexión y probá de nuevo."); return false; }
  return true;
}
async function del(col, id) {
  delete D[col][id]; pedirRender();
  const { error } = await SB.from("docs").delete().eq("col", col).eq("id", id);
  if (error) { console.error(error); toast("No se pudo borrar. Probá de nuevo."); return false; }
  return true;
}
async function putConfig(data) {
  D.config = { ...D.config, ...data }; pedirRender();
  const { error } = await SB.from("docs").upsert({ col: "config", id: "main", data: D.config, updated_at: new Date().toISOString() });
  if (error) { console.error(error); toast("No se pudo guardar la configuración."); }
}
async function putMuchos(filas) {
  for (let i = 0; i < filas.length; i += 400) {
    const { error } = await SB.from("docs").upsert(filas.slice(i, i + 400).map((f) => ({ ...f, updated_at: new Date().toISOString() })));
    if (error) throw error;
  }
}''')

rep('''async function iniciar() {
  try { db = window.claude && claude.use ? await claude.use("db") : null; } catch (e) { db = null; }
  try { downloads = window.claude && claude.use ? await claude.use("downloads") : null; } catch (e) { downloads = null; }
  if (!db) {
    modoLocal = true; cargarLocal(); listo = true;
    $("#syncState").textContent = "Guardado solo en este dispositivo";
    render(); return;
  }
  $("#syncState").textContent = "Sincronizado: compu y celular";
  const esperar = new Set(["config", ...COLS]);
  const marcar = (k) => { esperar.delete(k); if (!esperar.size && !listo) { listo = true; } pedirRender(); };
  const onErr = () => { $("#syncState").textContent = "Sin conexión: recargá la página"; };
  db.doc("config/main").onSnapshot((s) => { D.config = { ...DEF_CONFIG, ...(s.exists ? s.data() : {}) }; marcar("config"); }, onErr);
  COLS.forEach((c) => db.collection(c).limit(1000).onSnapshot((qs) => { const o = {}; qs.docs.forEach((d) => (o[d.id] = { id: d.id, ...d.data() })); D[c] = o; marcar(c); }, onErr));
  setTimeout(() => { if (!listo) { listo = true; pedirRender(); } }, 6000);
}''', '''/* ---- Sesión ---- */
function pantallaLogin(msg) {
  $("#appRoot").hidden = true; $("#bottomNav").hidden = true; $("#loginRoot").hidden = false;
  $("#loginRoot").innerHTML = '<div class="login"><form class="login-card" data-form="login"><div class="brand"><div class="brand-mark" aria-hidden="true">C</div><div><div class="brand-name">Mis Consultorios</div><div class="brand-sub">Agenda, alquileres y cobros</div></div></div>' +
    (msg ? '<div class="note ' + (msg.tipo || "info") + '">' + msg.html + "</div>" : "<h1>Entrar</h1>") +
    (msg && msg.sinForm ? "" : '<div class="field"><label for="lg-mail">Tu mail</label><input class="inp" id="lg-mail" name="email" type="email" autocomplete="email" required value="' + esc((msg && msg.mail) || "") + '"></div>' +
      '<div class="field"><label for="lg-pass">Contraseña</label><input class="inp" id="lg-pass" name="clave" type="password" autocomplete="current-password"></div><button class="btn primary" type="submit">Entrar</button>' +
      '<button type="button" class="btn ghost" data-a="login-enlace">Es mi primera vez u olvidé la contraseña</button>') +
    (msg && msg.salir ? '<button type="button" class="btn" data-a="salir">Entrar con otro mail</button>' : "") + "</form></div>";
}
function pantallaClave(msg) {
  $("#appRoot").hidden = true; $("#bottomNav").hidden = true; $("#loginRoot").hidden = false;
  $("#loginRoot").innerHTML = '<div class="login"><form class="login-card" data-form="clave"><h1>Creá tu contraseña</h1><p class="muted" style="margin:0">La vas a usar junto con tu mail para entrar desde cualquier dispositivo. Mínimo 8 caracteres.</p>' +
    (msg ? '<div class="note warn">' + esc(msg) + "</div>" : "") +
    '<div class="field"><label for="ck-1">Contraseña nueva</label><input class="inp" id="ck-1" name="c1" type="password" autocomplete="new-password" minlength="8" required></div>' +
    '<div class="field"><label for="ck-2">Repetila</label><input class="inp" id="ck-2" name="c2" type="password" autocomplete="new-password" minlength="8" required></div><button class="btn primary" type="submit">Guardar y entrar</button></form></div>';
}
function mostrarApp() { $("#loginRoot").hidden = true; $("#appRoot").hidden = false; $("#bottomNav").hidden = false; }
async function cargarTodo() {
  const filas = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await SB.from("docs").select("col,id,data").range(from, from + 999);
    if (error) throw error;
    filas.push(...data); if (data.length < 1000) break;
  }
  COLS.forEach((c) => (D[c] = {}));
  D.config = { ...DEF_CONFIG };
  for (const f of filas) aplicarFila(f);
  if (ROL === "profesional") await cargarAgenda();
}
function aplicarFila(f) {
  if (f.col === "config") { if (f.id === "main") D.config = { ...DEF_CONFIG, ...f.data }; return; }
  if (D[f.col]) D[f.col][f.id] = { id: f.id, ...f.data };
}
async function cargarAgenda() {
  const { data, error } = await SB.rpc("agenda_ocupada");
  if (error || !data) return;
  for (const k of Object.keys(D.series)) if (k.startsWith("x")) delete D.series[k];
  for (const k of Object.keys(D.ocupaciones)) if (k.startsWith("x")) delete D.ocupaciones[k];
  for (const x of data.series || []) D.series[x.id] = x;
  for (const x of data.ocupaciones || []) D.ocupaciones[x.id] = x;
}
let canal = null;
function escucharCambios() {
  if (canal) SB.removeChannel(canal);
  canal = SB.channel("docs").on("postgres_changes", { event: "*", schema: "public", table: "docs" }, (p) => {
    if (p.eventType === "DELETE") { const o = p.old || {}; if (o.col && D[o.col]) delete D[o.col][o.id]; }
    else aplicarFila(p.new);
    pedirRender();
  }).subscribe((st) => { $("#syncState").textContent = st === "SUBSCRIBED" ? "Sincronizado" : st === "CHANNEL_ERROR" || st === "TIMED_OUT" ? "Sin conexión en vivo: recargá" : "Conectando…"; });
}
async function iniciar() {
  const { data: { session } } = await SB.auth.getSession();
  if (!session) return pantallaLogin();
  const { data: v, error } = await SB.rpc("vincular");
  if (error) { console.error(error); return pantallaLogin({ tipo: "warn", html: "No pude conectar con la base de datos.<br><small>" + esc((error.code ? error.code + " · " : "") + (error.message || "")) + "</small>", salir: true, sinForm: true }); }
  MI_MAIL = v.email || session.user.email || "";
  if (!v.rol) return pantallaLogin({ tipo: "warn", html: "Entraste como <b>" + esc(MI_MAIL) + "</b>, pero ese mail no está cargado en ningún profesional. Pedile al dueño que lo agregue en tu ficha y volvé a entrar.", salir: true, sinForm: true });
  if (!(session.user.user_metadata || {}).clave) return pantallaClave();
  ROL = v.rol; MI_PROF = v.prof_id || null;
  mostrarApp();
  $("#userMail").textContent = MI_MAIL;
  try { await cargarTodo(); } catch (e) { console.error(e); toast("No se pudieron cargar los datos. Recargá la página."); }
  if (ROL === "profesional") { UI.modo = "prof"; UI.profVista = MI_PROF; setInterval(async () => { await cargarAgenda(); pedirRender(); }, 60000); }
  listo = true; escucharCambios(); render();
  if (ROL === "dueno") setTimeout(() => cargosAutomaticos().catch(console.error), 1500);
}
SB.auth.onAuthStateChange((ev) => { if (ev === "SIGNED_IN" && !listo && !ROL) iniciar(); if (ev === "SIGNED_OUT") location.reload(); });''')

# banner sin modo local
rep('''(modoLocal ? '<div class="banner note warn">Esta vista no puede sincronizar: los datos quedan solo en este navegador. Abrí la app desde Claude para usarla en la compu y el celular.</div>' : "") + html''', 'html')

# ---------- vista del profesional: real vs vista previa ----------
rep('''  const banner = '<div class="pv-banner" role="note">''', '''  const banner = ROL === "profesional" ? "" : '<div class="pv-banner" role="note">''')
rep('''    if (!prof(UI.profVista) || prof(UI.profVista).activo === false) { const pa = profesionalesAct()[0]; if (pa) UI.profVista = pa.id; else UI.modo = "dueno"; }''',
    '''    if (ROL !== "profesional" && (!prof(UI.profVista) || prof(UI.profVista).activo === false)) { const pa = profesionalesAct()[0]; if (pa) UI.profVista = pa.id; else UI.modo = "dueno"; }
    if (ROL === "profesional" && !prof(UI.profVista)) { $("#main").innerHTML = '<div class="loading">No encontramos tu ficha. Pedile al dueño que revise tu mail.</div>'; return; }''')
rep('''    case "pv-cancelar": await cancelarItem(el.dataset.key); render(); break;''',
    '''    case "pv-cancelar": {
      if (ROL !== "profesional") { await cancelarItem(el.dataset.key); render(); break; }
      const { data, error } = await SB.rpc("pv_cancelar", { p_key: el.dataset.key });
      if (error) { toast(error.message || "No se pudo cancelar."); break; }
      cerrarModal(); await cargarTodo(); render(); toast(data && data.tarde ? "Cancelado. Se cobra igual por cancelar tarde." : "Cancelado sin costo."); break;
    }''')
rep('''    case "pv-confirmar": {
      const m = UI.modal, p = prof(UI.profVista);''', '''    case "pv-confirmar": {
      const m = UI.modal, p = prof(UI.profVista);
      if (ROL === "profesional") {
        el.disabled = true;
        const { data, error } = await SB.rpc("pv_reservar", { p_cons: m.cons, p_fecha: m.fecha, p_desde: m.desde, p_hasta: m.hasta, p_semanas: Number(m.rep || 1) });
        if (error) { el.disabled = false; cerrarModal(); await cargarAgenda(); render(); toast(error.message || "No se pudo reservar."); break; }
        cerrarModal(); await cargarTodo(); UI.pvTab = "inicio"; render(); toast((data.estado === "pendiente" ? "Pedido enviado: " : "Listo: ") + data.creadas + (data.creadas > 1 ? " reservas" : " reserva") + (data.salteadas && data.salteadas.length ? " (" + data.salteadas.length + " fechas ocupadas salteadas)" : "") + (data.estado === "pendiente" ? ". Te avisamos cuando el dueño apruebe." : "")); break;
      }''')
rep('''    case "pv-tab": UI.pvTab = v; cerrarModal(); render(); window.scrollTo(0, 0); break;''',
    '''    case "pv-tab": UI.pvTab = v; cerrarModal(); if (ROL === "profesional" && v === "reservar") await cargarAgenda(); render(); window.scrollTo(0, 0); break;
    case "salir": await SB.auth.signOut(); location.reload(); break;
    case "login-enlace": {
      const mail = String(($("#lg-mail") || {}).value || "").trim();
      if (!mail) { pantallaLogin({ tipo: "warn", html: "Escribí tu mail arriba y volvé a tocar el botón." }); break; }
      const { error } = await SB.auth.signInWithOtp({ email: mail, options: { emailRedirectTo: location.origin + "/" } });
      if (error) pantallaLogin({ tipo: "warn", html: "No se pudo mandar el enlace: " + esc(error.message) + ". Esperá un minuto y probá de nuevo.", mail });
      else pantallaLogin({ tipo: "good", html: "Te mandamos un enlace a <b>" + esc(mail) + "</b>. Abrilo, y ahí vas a crear tu contraseña. Si no llega, revisá spam.", sinForm: true, salir: true });
      break;
    }''')

# ---------- descargas con el navegador ----------
rep('''  if (!downloads) return toast("Esta vista no permite descargar archivos. Abrí la app desde Claude.");
''', '')
rep('''await downloads.save({ filename: "movimientos-" + hoy() + ".csv", data: "﻿" + rows''', '''bajar("movimientos-" + hoy() + ".csv", "﻿" + rows''')
rep('''.join(";")).join("\\n") });''', '''.join(";")).join("\\n"), "text/csv");''')
rep('''await downloads.save({ filename: "respaldo-consultorios-" + hoy() + ".json", data: JSON.stringify(out, null, 1) });''',
    '''bajar("respaldo-consultorios-" + hoy() + ".json", JSON.stringify(out, null, 1), "application/json");''')
rep('''async function exportar(tipo) {''', '''function bajar(nombre, texto, tipo) {
  const url = URL.createObjectURL(new Blob([texto], { type: tipo + ";charset=utf-8" }));
  const a = document.createElement("a"); a.href = url; a.download = nombre; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
async function exportar(tipo) {''')
rep('''    if (o.config) await putConfig(o.config);
    for (const c of COLS) for (const r of o[c] || []) if (r && r.id) await put(c, r.id, r);
    toast("Respaldo restaurado");''', '''    toast("Restaurando…");
    const filas = [];
    if (o.config) filas.push({ col: "config", id: "main", data: { ...D.config, ...o.config } });
    for (const c of COLS) for (const r of o[c] || []) if (r && r.id) { const d = { ...r }; delete d.id; filas.push({ col: c, id: r.id, data: d }); }
    const borrar = await SB.from("docs").delete().neq("col", "");
    if (borrar.error) throw borrar.error;
    await putMuchos(filas); await cargarTodo(); render();
    toast("Respaldo restaurado: " + filas.length + " registros");''')

# ---------- ajustes: accesos ----------
rep('''(modoLocal ? '<p class="small muted" style="margin:0">En este modo los datos viven solo en este navegador.</p>' : '<p class="small muted" style="margin:0">Los datos se guardan en tu cuenta de Claude y se ven igual desde la compu y el celular. Solo vos podés abrir esta app mientras no la compartas.</p>') + "</div></section>";''',
    '''"</div></section>" +
    '<section class="panel"><div class="panel-h"><h2>Accesos</h2></div><div class="panel-b" style="display:flex;flex-direction:column;gap:12px">' +
    '<p class="muted" style="margin:0">Para que un profesional entre, cargá su mail en su ficha (Profesionales). Después entra a esta misma dirección con ese mail y ve solo lo suyo.</p>' +
    '<div id="listaAccesos" class="small muted">Cargando…</div>' +
    '<form data-form="dueno-nuevo" class="tools"><div class="field" style="flex:1 1 220px"><label for="dn-mail">Sumar otro dueño o socio por mail</label><input class="inp" id="dn-mail" name="email" type="email" required></div><button class="btn" type="submit" style="align-self:flex-end">Hacer dueño</button></form></div></section>';''')
rep('''/* ============ Modales ============ */''', '''async function pintarAccesos() {
  const el = $("#listaAccesos"); if (!el) return;
  const { data, error } = await SB.from("miembros").select("email,rol,prof_id").order("rol");
  if (error) { el.textContent = "No se pudo leer la lista."; return; }
  el.innerHTML = data.length ? '<div class="rows">' + data.map((m) => '<div class="row"><div class="row-main"><span class="row-title">' + esc(m.email) + '</span><span class="small muted">' + (m.rol === "dueno" ? "Dueño" : "Profesional · " + esc(nomProf(m.prof_id))) + "</span></div></div>").join("") + "</div>" : "Nadie entró todavía.";
}

/* ============ Modales ============ */''')
rep('''  const sc2 = document.querySelector(".grid-scroll"); if (sc2 && left) sc2.scrollLeft = left;''',
    '''  const sc2 = document.querySelector(".grid-scroll"); if (sc2 && left) sc2.scrollLeft = left;
  if (UI.tab === "mas" && UI.seccionMas === "ajustes") pintarAccesos();''')
rep('''    case "socio": {''', '''    case "login": {
      const mail = String(fd.get("email") || "").trim(), clave = String(fd.get("clave") || "");
      if (!mail) return;
      if (!clave) { pantallaLogin({ tipo: "warn", html: "Poné tu contraseña. Si es tu primera vez o no la recordás, tocá el botón de abajo y te mandamos un enlace por mail.", mail }); break; }
      const { error } = await SB.auth.signInWithPassword({ email: mail, password: clave });
      if (error) pantallaLogin({ tipo: "warn", html: /invalid/i.test(error.message) ? "Mail o contraseña incorrectos. Si todavía no creaste tu contraseña, tocá <b>Es mi primera vez</b>." : "No se pudo entrar: " + esc(error.message), mail });
      else iniciar();
      break;
    }
    case "clave": {
      const c1 = String(fd.get("c1") || ""), c2 = String(fd.get("c2") || "");
      if (c1.length < 8) return pantallaClave("Tiene que tener al menos 8 caracteres.");
      if (c1 !== c2) return pantallaClave("Las dos contraseñas no coinciden.");
      const { error } = await SB.auth.updateUser({ password: c1, data: { clave: true } });
      if (error) return pantallaClave("No se pudo guardar: " + error.message);
      toast("Contraseña guardada"); iniciar(); break;
    }
    case "dueno-nuevo": {
      const { data, error } = await SB.rpc("hacer_dueno", { mail: g("email") });
      toast(error ? "No se pudo." : data ? "Listo, ahora es dueño" : "Invitado: cuando entre con ese mail, va a ser dueño"); pintarAccesos(); break;
    }
    case "socio": {''')

rep('>Restaurar desde archivo</label>', '>Restaurar desde archivo (reemplaza todo)</label>')

# ---------- invitar profesional por mail ----------
rep("""<button type="button" class="btn" data-a="pv-entrar" data-id="' + p.id + '">Ver la app como '""",
    """' + (p.email ? '<button type="button" class="btn" data-a="invitar" data-id="' + p.id + '">Mandarle acceso por mail</button>' : "") + '<button type="button" class="btn" data-a="pv-entrar" data-id="' + p.id + '">Ver la app como '""")
rep("""    case "salir": await SB.auth.signOut(); location.reload(); break;""", """    case "salir": await SB.auth.signOut(); location.reload(); break;
    case "invitar": {
      const p = prof(id); if (!p || !p.email) break;
      el.disabled = true;
      const { error } = await SB.auth.signInWithOtp({ email: String(p.email).trim(), options: { emailRedirectTo: location.origin + "/" } });
      el.disabled = false;
      toast(error ? "No se pudo mandar: " + error.message : "Listo: le mandamos un mail a " + String(p.email).trim() + " para entrar (que revise spam)"); break;
    }""")
# ---------- contratos desde la app del profesional: los valida la base ----------
rep("""      const S = UI.cf, paraDueno = !!UI.modal, fin = finContrato(S.inicio, S.plazo);
      if (!S.franjas.length) break;""", """      const S = UI.cf, paraDueno = !!UI.modal, fin = finContrato(S.inicio, S.plazo);
      if (!S.franjas.length) break;
      if (ROL === "profesional") {
        el.disabled = true;
        const { data, error } = await SB.rpc("pv_contratar", { p_franjas: S.franjas, p_inicio: S.inicio, p_plazo: S.plazo });
        el.disabled = false;
        if (error) { await cargarAgenda(); render(); toast(error.message || "No se pudo confirmar."); break; }
        UI.cf = null; await cargarTodo(); UI.pvTab = "inicio"; render(); window.scrollTo(0, 0);
        toast(data.estado === "pendiente" ? "Pedido enviado. Te avisamos cuando el dueño lo apruebe." : "Listo: horario fijo confirmado"); break;
      }""")
rep("""      const c = D.contratos[id]; if (!c) break;
      const r = await renovarContrato(c);""", """      const c = D.contratos[id]; if (!c) break;
      if (ROL === "profesional") {
        const { data, error } = await SB.rpc("pv_renovar", { p_id: id });
        if (error) { toast(error.message || "No se pudo renovar."); break; }
        await cargarTodo(); render(); toast("Renovado hasta el " + fCorta(data.fin) + "/" + data.fin.slice(2, 4)); break;
      }
      const r = await renovarContrato(c);""")
open('index.html', 'w', encoding='utf-8').write(s)
print('index.html', len(s))
