#!/usr/bin/env node
// Guard: this project runs through Docker only (repo-wide rule — no host npm).
// Wraps every package.json script; refuses to run outside a container.
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';

const command = process.argv[2];
const args = process.argv.slice(3);
const inDocker =
	existsSync('/.dockerenv') ||
	process.env.GROBASE_IN_DOCKER === '1' ||
	process.env.TRACK_BINOCLE_IN_DOCKER === '1';

if (!inDocker) {
	console.error('grobase-site runs through Docker only. Use `make grobase-up` from the repository root.');
	process.exit(1);
}

if (!command) {
	console.error('No container command was provided.');
	process.exit(2);
}

const child = spawn(command, args, {
	stdio: 'inherit',
	env: {
		...process.env,
		PATH: `${process.cwd()}/node_modules/.bin:${process.env.PATH ?? ''}`,
		GROBASE_IN_DOCKER: '1',
	},
});

child.on('error', (error) => {
	console.error(error.message);
	process.exit(1);
});

child.on('exit', (code, signal) => {
	if (signal) {
		process.kill(process.pid, signal);
		return;
	}
	process.exit(code ?? 0);
});
