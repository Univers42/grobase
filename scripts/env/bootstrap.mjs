#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   bootstrap.mjs                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */


console.log('[bootstrap] Generating BaaS and website runtime environment...');
await import('./bootstrap-env.mjs');

console.log('[bootstrap] Ensuring osionos bridge runtime secrets...');
await import('./ensure-osionos-runtime-secrets.mjs');

console.log('[bootstrap] Runtime environment is ready. Next: docker compose up -d --build');
