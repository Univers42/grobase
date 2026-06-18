ss -tuln | grep LISTEN
lsof -i :3000
kill -9 <PID>


When it's killed we should not be able to acced the platform anymore because we need low-level acces.

```bash

7:05:34 PM [vite] http proxy error: /api/auth/me
Error: connect ECONNREFUSED 127.0.0.1:3000
    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1637:16)
7:05:34 PM [vite] http proxy error: /api/auth/me
Error: connect ECONNREFUSED 127.0.0.1:3000
    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1637:16) (x2)
7:05:42 PM [vite] http proxy error: /api/auth/login
Error: connect ECONNREFUSED 127.0.0.1:3000
    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1637:16)
7:05:53 PM [vite] http proxy error: /api/auth/login
Error: connect ECONNREFUSED 127.0.0.1:3000
    at TCPConnectWrap.afterConnect [as oncomplete] (node:net:1637:16) (x2)



```