# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Dockerfile                                         :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/02 23:39:42 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/04 16:33:36 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

# syntax=docker/dockerfile:1
FROM public.ecr.aws/docker/library/kong:3.8

ENV MINI_BAAS_CONFIG_FILE=/etc/mini-baas/mini-baas-infra.conf
USER root
RUN mkdir -p /etc/mini-baas /etc/kong
COPY --chmod=0644 config/mini-baas-infra.conf /etc/mini-baas/mini-baas-infra.conf
COPY --chmod=0644 config/kong.track-binocle.yml /etc/kong/kong.yml.tmpl

EXPOSE 8000 8001

USER kong
