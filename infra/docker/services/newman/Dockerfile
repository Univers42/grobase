# mini-baas-newman:local — newman + the htmlextra reporter, for the edge corpus
# runner (scripts/test/postman/run-edge-postman.sh expects this tag). The default
# postman/newman image lacks newman-reporter-htmlextra, so the edge run needs this
# thin layer on top.
FROM postman/newman:6-alpine
RUN npm install -g newman-reporter-htmlextra@1.23.1
# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint -- ephemeral CI/test runner (edge postman corpus), not a runtime service
ENTRYPOINT ["newman"]
