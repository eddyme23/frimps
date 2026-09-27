// GF-compatible legacy SSH payload gateway.  This is deliberately a raw TCP
// proxy: legacy clients send HTTP-looking text followed by SSH, not RFC 6455.
const net = require('net');

const listenPort = Number(process.argv[2] || 3104);
const sshHost = process.argv[3] || '127.0.0.1';
const sshPort = Number(process.argv[4] || 143);

net.createServer((client) => {
  let buffered = Buffer.alloc(0);
  let answered = false;
  let bridged = false;
  let upstream;

  function close() {
    if (upstream) upstream.destroy();
    client.destroy();
  }

  client.on('data', (chunk) => {
    if (bridged) return;
    buffered = Buffer.concat([buffered, chunk]);
    if (!answered && buffered.length > 5) {
      answered = true;
      const connect = buffered.subarray(0, 7).toString('ascii').toUpperCase() === 'CONNECT';
      client.write(connect ? 'HTTP/1.1 200 OK\r\n\r\n' : 'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
    }
    const marker = buffered.indexOf(Buffer.from('SSH-'));
    if (marker < 0) return;
    bridged = true;
    client.removeAllListeners('data');
    upstream = net.connect(sshPort, sshHost, () => {
      upstream.write(buffered.subarray(marker));
      client.pipe(upstream);
      upstream.pipe(client);
    });
    upstream.on('error', close);
    upstream.on('close', () => client.destroy());
  });
  client.on('error', () => {});
  client.on('close', () => { if (upstream) upstream.destroy(); });
}).listen(listenPort, '127.0.0.1');
