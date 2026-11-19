// Traffic generator for the "demo" profile. Runs inside the app image.
//
// It registers a source with the receiver container as its destination and
// then keeps sending webhooks: mostly valid ones, now and then a repeated
// idempotency key or a wrong signature, so every panel on the dashboard has
// something to show.

import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';

import { sign } from '/app/src/signature.js';

const APP_URL = process.env.APP_URL ?? 'http://app:3000';
const RECEIVER_URL = process.env.RECEIVER_URL ?? 'http://receiver:9000/hook';
const SOURCE_NAME = 'demo-shop';
const TOPICS = ['orders/create', 'orders/paid', 'orders/cancelled', 'customers/create'];

const adminHeaders = {
  authorization: `Bearer ${process.env.ADMIN_TOKEN}`,
  'content-type': 'application/json',
};

async function api(method, path, body) {
  const response = await fetch(`${APP_URL}${path}`, {
    method,
    headers: adminHeaders,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`${method} ${path} answered ${response.status}: ${await response.text()}`);
  }
  return response.status === 204 ? null : response.json();
}

// The signing secret is only returned when a source is created, so a source
// left over from an earlier run is replaced by a fresh one.
async function createSource() {
  const { data } = await api('GET', '/api/sources');
  const existing = data.find((source) => source.name === SOURCE_NAME);
  if (existing) await api('DELETE', `/api/sources/${existing.id}`);

  const source = await api('POST', '/api/sources', { name: SOURCE_NAME });
  await api('POST', `/api/sources/${source.id}/destinations`, { url: RECEIVER_URL });
  return source;
}

const pick = (items) => items[Math.floor(Math.random() * items.length)];

async function sendWebhook(source, state) {
  const order = { id: state.nextOrderId, total: Math.round(Math.random() * 20000) / 100 };
  state.nextOrderId += 1;
  const body = JSON.stringify({ topic: pick(TOPICS), order });

  const roll = Math.random();
  const wrongSignature = roll < 0.05;
  const repeatKey = roll >= 0.05 && roll < 0.15 && state.lastKey !== null;

  const key = repeatKey ? state.lastKey : randomUUID();
  state.lastKey = key;

  const response = await fetch(`${APP_URL}${source.ingest_path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'idempotency-key': key,
      'x-signature': sign(wrongSignature ? 'not-the-secret' : source.secret, body),
    },
    body,
  });
  // The connection is reused only after the body has been read.
  await response.arrayBuffer();
  return response.status;
}

const source = await createSource();
console.log(`sending webhooks to ${source.ingest_path}`);

const state = { nextOrderId: 1000, lastKey: null };
const counts = {};
let lastReport = Date.now();

for (;;) {
  try {
    const status = await sendWebhook(source, state);
    counts[status] = (counts[status] ?? 0) + 1;
  } catch (err) {
    console.error(`request failed: ${err.cause?.code ?? err.message}`);
  }

  if (Date.now() - lastReport >= 30_000) {
    console.log(`responses so far: ${JSON.stringify(counts)}`);
    lastReport = Date.now();
  }

  await sleep(300 + Math.random() * 1200);
}
