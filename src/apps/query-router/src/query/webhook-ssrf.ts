/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   webhook-ssrf.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 23:40:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/09/23 23:40:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
/**
 * SSRF guard for automation webhooks: the private-address classifiers, the
 * connect-time `publicOnlyLookup`, and the pinned HTTPS POST that uses it.
 */

import { lookup as dnsLookup, type LookupOptions } from 'node:dns';
import { request as httpsRequest } from 'node:https';
import { isIP, type LookupFunction } from 'node:net';

/**
 * @brief Classify an already-parsed IP literal as non-public (SSRF block-list).
 *
 * Unmaps an IPv4-mapped-IPv6 literal (`::ffff:169.254.169.254`) to its dotted
 * form first — the documented bypass for hostname denylists — then applies the
 * IPv4 / IPv6 private-range rules: loopback, RFC1918/ULA private, link-local
 * (incl. the 169.254.169.254 cloud-metadata range) and CGNAT. Anything not
 * parseable as an IP fails closed (treated as private).
 *
 * @see https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
 *
 * Exported for unit tests.
 */
export function isPrivateAddress(ip: string): boolean {
  let addr = ip;
  // Unmap a *dotted* IPv4-mapped IPv6 literal (::ffff:169.254.169.254) so the
  // IPv4 rules below catch it. The WHATWG URL parser may instead hand us the
  // *hex* form (::ffff:a9fe:a9fe) — that is caught wholesale in the IPv6 branch
  // below (any address that is not global-unicast is refused).
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(addr);
  if (mapped) addr = mapped[1];
  const fam = isIP(addr);
  if (fam === 4) {
    const o = addr.split('.').map(Number);
    return (
      o[0] === 0 ||
      o[0] === 10 ||
      o[0] === 127 ||
      (o[0] === 169 && o[1] === 254) || // link-local + cloud metadata
      (o[0] === 172 && o[1] >= 16 && o[1] <= 31) || // 172.16.0.0/12
      (o[0] === 192 && o[1] === 168) || // 192.168.0.0/16
      (o[0] === 100 && o[1] >= 64 && o[1] <= 127) // CGNAT 100.64.0.0/10
    );
  }
  if (fam === 6) {
    // Global-unicast IPv6 (the only public range, 2000::/3) never starts with
    // `::`, so refusing every `::*` form blocks loopback (::1), unspecified (::)
    // and BOTH encodings of IPv4-mapped/-compatible addresses (::ffff:a9fe:a9fe
    // and ::ffff:169.254.169.254) — closing the IPv4-mapped-IPv6 bypass. ULA
    // (fc/fd), link-local (fe80) and multicast (ff) are likewise non-public.
    const lower = addr.toLowerCase();
    return (
      lower.startsWith('::') ||
      lower.startsWith('fe80:') ||
      lower.startsWith('fc') ||
      lower.startsWith('fd') ||
      lower.startsWith('ff')
    );
  }
  return true; // not an IP literal → fail closed
}

/**
 * @brief Strict SSRF classifier, used only while AUTOMATION_WEBHOOK_IP_PIN_ENABLED is ON.
 *
 * IPv4: `isPrivateAddress`'s ranges plus 192.0.0.0/24, the three TEST-NETs,
 * 198.18.0.0/15 and 224.0.0.0/3 (multicast, reserved, broadcast). IPv6 is public
 * only inside 2000::/3, minus 2001::/23, 2001:db8::/32 and 2002::/16 (6to4), so
 * all of fe80::/10, ULA, multicast and `::` fail. IPv4-mapped `::ffff:0:0/96`
 * (dotted or hex) and NAT64 `64:ff9b::/96` are judged by the IPv4 they embed.
 * Non-IP input fails closed. The flag-OFF path keeps `isPrivateAddress` as is.
 * Exported for tests.
 */
export function isPrivateAddressStrict(ip: string): boolean {
  const fam = isIP(ip);
  if (fam === 4) return isNonPublicV4(ip.split('.').map(Number));
  if (fam === 6) return isNonPublicV6(ipv6Hextets(ip));
  return true;
}

/** True when the IPv4 octets `o` are in a non-public range of the strict set. */
function isNonPublicV4(o: number[]): boolean {
  switch (o[0]) {
    case 0:
    case 10:
    case 127:
      return true;
    case 100:
      return o[1] >= 64 && o[1] <= 127;
    case 169:
      return o[1] === 254;
    case 172:
      return o[1] >= 16 && o[1] <= 31;
    case 192:
      return o[1] === 168 || (o[1] === 0 && (o[2] === 0 || o[2] === 2));
    case 198:
      return o[1] === 18 || o[1] === 19 || (o[1] === 51 && o[2] === 100);
    case 203:
      return o[1] === 0 && o[2] === 113;
    default:
      return o[0] >= 224;
  }
}

/** True when the eight IPv6 groups `h` are not a public unicast address of the strict set. */
function isNonPublicV6(h: number[]): boolean {
  const v4 = embeddedV4(h);
  if (v4) return isNonPublicV4(v4);
  if (h[0] < 0x2000 || h[0] > 0x3fff || h[0] === 0x2002) return true;
  return h[0] === 0x2001 && (h[1] < 0x200 || h[1] === 0xdb8);
}

/**
 * The IPv4 octets carried by an IPv4-mapped (::ffff:0:0/96) or NAT64
 * (64:ff9b::/96) address, else undefined.
 */
function embeddedV4(h: number[]): number[] | undefined {
  const mapped = h[0] === 0 && h[1] === 0 && h[5] === 0xffff;
  const nat64 = h[0] === 0x64 && h[1] === 0xff9b && h[5] === 0;
  if (h[2] !== 0 || h[3] !== 0 || h[4] !== 0 || !(mapped || nat64)) return undefined;
  return [h[6] >> 8, h[6] & 0xff, h[7] >> 8, h[7] & 0xff];
}

/**
 * Expands an `isIP() === 6` literal to its eight 16-bit groups: drops a `%zone`,
 * fills the `::` gap with zeros and turns a dotted IPv4 tail into two groups.
 */
function ipv6Hextets(ip: string): number[] {
  const [head, tail] = ip.split('%')[0].split('::');
  const left = hextetsOf(head);
  const right = tail === undefined ? [] : hextetsOf(tail);
  return [...left, ...new Array<number>(8 - left.length - right.length).fill(0), ...right];
}

/** The 16-bit groups of a `::`-free IPv6 fragment; a dotted IPv4 group yields two. */
function hextetsOf(part: string): number[] {
  if (part === '') return [];
  return part.split(':').flatMap((group) => {
    if (!group.includes('.')) return [Number.parseInt(group, 16)];
    const [a, b, c, d] = group.split('.').map(Number);
    return [(a << 8) | b, (c << 8) | d];
  });
}

/**
 * @brief `net.LookupFunction` that only ever hands the socket a public address.
 *
 * Resolves every record for `hostname` and fails with code `EBLOCKED` when there
 * are none or any is non-public (`isPrivateAddressStrict`), so a DNS rebind
 * between the pre-check and the dial cannot reach an internal target. Answers in
 * the shape the caller asked for (`options.all` → the record array). Exported
 * for tests.
 */
export function publicOnlyLookup(
  hostname: string,
  options: LookupOptions,
  callback: Parameters<LookupFunction>[2],
): void {
  dnsLookup(hostname, { ...options, all: true }, (err, records) => {
    if (err) return callback(err, '');
    if (records.length === 0 || records.some((r) => isPrivateAddressStrict(r.address))) {
      return callback(
        Object.assign(
          new Error(`webhook target rejected at connect (EBLOCKED, non-public): ${hostname}`),
          { code: 'EBLOCKED' },
        ),
        '',
      );
    }
    if (options.all) return callback(null, records);
    callback(null, records[0].address, records[0].family);
  });
}

/**
 * @brief POST `body` over node:https, checking the peer address as the socket dials.
 *
 * `publicOnlyLookup` runs inside the connect, so the address checked is the one
 * connected, while SNI, certificate checks and `Host` stay the URL's hostname.
 * `agent: false` rules out a pooled socket dialled without the guard. Rejects on
 * a request error (EBLOCKED, TLS, abort) or a 3xx (the fetch path's
 * `redirect: 'error'`), else resolves; the response is destroyed as soon as its
 * status is known, so a slow or endless body cannot hold the socket open.
 */
export function postPinned(url: string, body: string, signal: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      url,
      {
        method: 'POST',
        lookup: publicOnlyLookup,
        agent: false,
        signal,
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      },
      (res) => {
        res.destroy();
        const status = res.statusCode ?? 0;
        if (status < 300 || status >= 400) return resolve();
        reject(new Error(`webhook redirect refused (${status})`));
      },
    );
    req.on('error', reject);
    req.end(body);
  });
}
