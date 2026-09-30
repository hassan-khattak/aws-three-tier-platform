'use strict';

// Callers supply only controlled fields, never raw errors, URLs or credentials.
function log(fields) {
  process.stdout.write(JSON.stringify({ timestamp: new Date().toISOString(), service: 'api', ...fields }) + '\n');
}

module.exports = { log };
