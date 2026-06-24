```bash
cd /home/dlesieur/Documents/studi/vite-gourmand/backend && npm run test:e2e
cd /home/dlesieur/Documents/studi/vite-gourmand/backend && timeout 60 npm run test:e2e || echo "E2E tests completed or timed out"
grep -r "it\s*(" /home/dlesieur/Documents/studi/vite-gourmand/backend/test/*.e2e-spec.ts | wc -l # how many E2E tests are defined?


## count test
grep -rE "it\(|test\(" /home/dlesieur/Documents/studi/vite-gourmand/backend/src --include="*.spec.ts" | wc -l
grep -r "it\s*(" /home/dlesieur/Documents/studi/vite-gourmand/backend/src/**/*.spec.ts | wc -l
grep -r "it\s*(" /home/dlesieur/Documents/studi/vite-gourmand/backend/test/*.e2e-spec.ts | wc -l

#
curl -s -X POST "http://localhost:3000/api/tests/run-all" -H "Content-Type: application/json" -d '{"verbose":true}' | head -c 2000
╭─ dlesieur ─ /home/dlesieur/Documents/studi/vite-gourmand/backend ─ dashroutes*                                                                          ⏳17:28:00
$ curl -s "http://localhost:3000/api/tests/results" | jq '.data.summary' 2>/dev/null || curl -s "http://localhost:3000/api/tests/results" | grep -o '"summary":{[^}]*}'
{
  "total": 133,
  "passed": 133,
  "failed": 0,
  "duration": 32575
}
```