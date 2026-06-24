# Snippet


```bash
curl -s "http://localhost:3000/api/tests/results" | jq '.' 2>/dev/null || curl -s "http://localhost:3000/api/tests/results"
curl -s -X POST "http://localhost:3000/api/tests/run-all" | jq '.' 2>/dev/null || curl -s -X POST "http://localhost:3000/api/tests/run-all"
sleep 3 && curl -s "http://localhost:3000/api/tests/status"

$ cd /home/dlesieur/Documents/studi/vite-gourmand/backend && npm test

> backend@0.0.1 test
> node --localstorage-file=/tmp/jest-storage node_modules/.bin/jest --runInBand

 PASS  src/common/guards/guards.spec.ts
 PASS  src/common/pipes/validation.pipe.spec.ts
 PASS  src/app.controller.spec.ts
 PASS  src/common/filters/filters.spec.ts
 PASS  src/order.service.spec.ts
 PASS  src/auth/password-reset.helpers.spec.ts

Test Suites: 6 passed, 6 total
Tests:       57 passed, 57 total
Snapshots:   0 total
Time:        0.474 s, estimated 1 s
Ran all test suites.

curl -s -X POST "http://localhost:3000/api/tests/run" -H "Content-Type: application/json" -d '{"testId":"unit","verbose":true}' | jq '.summary'
null

curl -s -X POST "http://localhost:3000/api/tests/run" -H "Content-Type: application/json" -d '{"testId":"unit","verbose":true}'
```