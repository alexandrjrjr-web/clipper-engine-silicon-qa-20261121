import http from 'node:http';
import crypto from 'node:crypto';

const secret=process.env.CLIPPER_ACCESS_TOKEN || '';
if (secret.length < 32) throw new Error('CLIPPER_ACCESS_TOKEN must be 32+ characters.');
const cookieName='__Host-clipperpreview';
const session=crypto.createHmac('sha256',secret).update('ephemeral-2026-11-m1-preview').digest('hex');
const upstreamHost='127.0.0.1';
const upstreamPort=7377;
const listenPort=7399;

function equalSafe(a,b) {
  if (typeof a!=='string'||a.length!==b.length) return false;
  return crypto.timingSafeEqual(Buffer.from(a),Buffer.from(b));
}
function isAuthorized(req) {
  const cookies=(req.headers.cookie||'').split(';').map(x=>x.trim());
  const found=cookies.find(x=>x.startsWith(cookieName+'='));
  return found && equalSafe(found.slice(cookieName.length+1),session);
}
function reply(req,res) {
  let url;
  try { url=new URL(req.url,'http://preview.invalid'); }
  catch { res.writeHead(400); res.end('Bad URL'); return; }
  if(url.pathname==='/__proxy-ping') {
    res.writeHead(200,{'Content-Type':'text/plain','Cache-Control':'no-store'});
    res.end('clipper-proxy-ready');return;
  }
  if(url.pathname==='/__access') {
    const provided=url.searchParams.get('key')||'';
    if(equalSafe(provided,secret)) {
      res.writeHead(303,{
        'Location':'/',
        'Set-Cookie':cookieName+'='+session+'; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=7200',
        'Referrer-Policy':'no-referrer','Cache-Control':'no-store'});
      res.end(); return;
    }
  }
  if(!isAuthorized(req)) {
    res.writeHead(401,{'Content-Type':'text/html; charset=utf-8',
      'Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'});
    res.end('<!doctype html><html lang="pt-br"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Clipper Engine | acesso temporário</title><main style="max-width:500px;margin:10vh auto;font:16px system-ui;padding:24px"><h1>Clipper Engine no Mac M1</h1><p>Instância de testes temporária, protegida. Abra o link privado fornecido nesta conversa ou informe sua chave de acesso.</p><form action="/__access" method="GET"><label>Chave de acesso <input name="key" type="password" autocomplete="off" required style="display:block;width:100%;padding:12px;margin:12px 0"></label><button style="padding:12px 24px">Entrar</button></form><p>Não há contas pessoais conectadas nesta máquina virtual.</p></main></html>');
    return;
  }
  proxyRequest(req,res);
}
function forwardHeaders(incoming) {
  const h={...incoming};
  for(const key of ['host','connection','proxy-connection','upgrade','x-forwarded-for','x-forwarded-host','x-forwarded-proto']) delete h[key];
  // Clipper canonicalizes localhost; forward Host localhost to avoid a redirect loop.
  h.host='localhost:'+upstreamPort;
  h['x-forwarded-proto']='http';
  h['x-forwarded-host']=h.host;
  // Normalize browser Origin/Referer from HTTPS tunnel to the local service.
  if(h.origin) h.origin='http://'+h.host;
  if(h.referer) h.referer='http://'+h.host+'/';
  if(h.cookie) {
    h.cookie=h.cookie.split(';').map(x=>x.trim())
      .filter(x=>!x.startsWith(cookieName+'=')).join('; ');
  }
  return h;
}
function proxyRequest(req,res) {
  const upstream=http.request({
    hostname:upstreamHost,port:upstreamPort,
    path:req.url,method:req.method,headers:forwardHeaders(req.headers),
    timeout:120000,
  },up=>{
    const h={...up.headers};
    for(const key of ['connection','transfer-encoding','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','upgrade']) {
      if(key==='transfer-encoding') continue;
      delete h[key];
    }
    const location=String(h.location||'');
    if(/^http:\/\/(localhost|127\.0\.0\.1):7377\//.test(location)) {
      h.location=location.replace(/^http:\/\/(localhost|127\.0\.0\.1):7377/,'');
    }
    h['referrer-policy']='no-referrer';
    h['cache-control']='no-store';
    res.writeHead(up.statusCode||502,h);
    up.pipe(res);
  });
  upstream.on('timeout',()=>upstream.destroy(new Error('Upstream timed out')));
  upstream.on('error',err=>{
    console.error('Upstream error:',err.message);
    if(!res.headersSent) res.writeHead(502,{'Content-Type':'text/plain'});
    res.end('Clipper Engine is starting or temporarily unavailable.');
  });
  req.pipe(upstream);
}
// WebSockets are forwarded without framing changes so the app can use live updates.
const server=http.createServer(reply);
server.on('upgrade',(req,socket,head)=>{
  if(!isAuthorized(req)){ socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');return; }
  const h=forwardHeaders(req.headers);
  h.connection='Upgrade';
  h.upgrade=req.headers.upgrade||'websocket';
  const out=http.request({
    hostname:upstreamHost,port:upstreamPort,path:req.url,method:req.method,headers:h,
  });
  out.on('upgrade',(response,remote,remoteHead)=>{
    let start='HTTP/1.1 '+response.statusCode+' '+response.statusMessage+'\r\n';
    for(const [name,value] of Object.entries(response.headers)) {
      if(value!==undefined) start+=name+': '+String(value)+'\r\n';
    }
    socket.write(start+'\r\n');
    if(remoteHead.length) socket.write(remoteHead);
    if(head.length) remote.write(head);
    socket.pipe(remote).pipe(socket);
    remote.on('error',()=>socket.destroy());
    socket.on('error',()=>remote.destroy());
  });
  out.on('response',response=>{
    socket.end('HTTP/1.1 '+response.statusCode+' '+response.statusMessage+'\r\nConnection: close\r\n\r\n');
  });
  out.on('error',()=>socket.destroy());
  out.end();
});
server.listen(listenPort,'127.0.0.1',()=>{
  console.log('ACCESS_PROXY_READY 127.0.0.1:'+listenPort+' -> 127.0.0.1:'+upstreamPort);
});
