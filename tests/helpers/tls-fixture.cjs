'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

function createTlsFixture() {
  const directory = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'assessment-tls-')));
  fs.chmodSync(directory, 0o700);
  const file = (name) => path.join(directory, name);
  const run = (args) => execFileSync('openssl', args, { cwd: directory, stdio: 'pipe', timeout: 15000 });
  try {
    fs.writeFileSync(file('ca.cnf'), '[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=Assessment Test CA\n[ca]\nbasicConstraints=critical,CA:true\nkeyUsage=critical,keyCertSign,cRLSign\n');
    run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-keyout', 'ca.key', '-out', 'ca.crt', '-config', 'ca.cnf']);
    run(['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', 'server.key', '-out', 'server.csr', '-subj', '/CN=localhost']);
    fs.writeFileSync(file('server.ext'), 'basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,DNS:postgres\n');
    run(['x509', '-req', '-in', 'server.csr', '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial', '-days', '2', '-out', 'server.crt', '-extfile', 'server.ext']);
    run(['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-keyout', 'other-ca.key', '-out', 'other-ca.crt', '-config', 'ca.cnf']);
    fs.chmodSync(file('server.key'), 0o600);
  } catch (error) {
    fs.rmSync(directory, { recursive: true, force: true });
    throw error;
  }
  return {
    directory,
    caFile: file('ca.crt'),
    untrustedCaFile: file('other-ca.crt'),
    serverFile: file('server.crt'),
    cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
  };
}

module.exports = { createTlsFixture };
