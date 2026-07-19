#!/usr/bin/env node
'use strict';

const { spawnSync, spawn } = require('child_process');
const path = require('path');
const os = require('os');
const fs = require('fs');

const REPO_URL = 'https://github.com/manhds82/claude-code-anyllm.git';
const INSTALL_DIR = path.join(os.homedir(), '.claude-bridge');

function ensureInstalled() {
  const marker = path.join(INSTALL_DIR, 'start-claude.ps1');
  if (!fs.existsSync(marker)) {
    console.log('[claude-bridge] First run — cloning to', INSTALL_DIR, '...');
    const r = spawnSync('git', ['clone', '--depth=1', REPO_URL, INSTALL_DIR], { stdio: 'inherit' });
    if (r.status !== 0) {
      console.error('[claude-bridge] git clone failed — is git installed?');
      process.exit(1);
    }
    console.log('[claude-bridge] Done. Run again to start the proxy.');
    process.exit(0);
  }
}

const args = process.argv.slice(2);

if (args[0] === '--update') {
  console.log('[claude-bridge] Pulling latest from GitHub...');
  spawnSync('git', ['-C', INSTALL_DIR, 'pull', '--ff-only'], { stdio: 'inherit' });
  process.exit(0);
}

ensureInstalled();

let child;
if (os.platform() === 'win32') {
  const script = path.join(INSTALL_DIR, 'start-claude.ps1');
  child = spawn('powershell', ['-ExecutionPolicy', 'Bypass', '-File', script, ...args], { stdio: 'inherit' });
} else {
  const script = path.join(INSTALL_DIR, 'start-claude.sh');
  spawnSync('chmod', ['+x', script]);
  child = spawn('bash', [script, ...args], { stdio: 'inherit' });
}

child.on('exit', (code) => process.exit(code || 0));
