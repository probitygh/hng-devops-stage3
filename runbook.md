# Blue/Green Deployment Runbook

## Alert Types and Responses

### 🚨 Failover Detected Alert

**What it means:**
- Traffic has automatically switched from one pool to another (Blue→Green or Green→Blue)
- This indicates the primary pool is unhealthy or returning errors

**Operator Actions:**
1. **Check primary pool health:**
   ```bash
   docker-compose logs app_blue  # or app_green
   curl http://localhost:8081/healthz  # Check blue health
   curl http://localhost:8082/healthz  # Check green health

2.   **Investigate the cause:**

Check application logs for errors

Verify resource usage (CPU, memory)

Check for network issues

3. **Recovery steps:**

If issue is resolved, stop chaos (if active):

`curl -X POST http://localhost:8081/chaos/stop`

Wait for automatic recovery (usually within 2-5 minutes)

Monitor traffic returns to primary pool.

**High Error Rate Alert**

What it means:

More than 2% of requests are returning 5xx errors in the last 200 requests

Service degradation is occurring

Operator Actions:

- Check current error rate:
`docker-compose logs alert_watcher | grep "High error rate"`

- Investigate upstream services:

### Check application logs
docker-compose logs app_blue | tail -20
docker-compose logs app_green | tail -20

### Check recent errors in Nginx logs

docker-compose exec nginx tail -100 /var/log/nginx/access.log | grep "upstream_status=5"


3. Immediate actions:

If errors persist, consider manual failover

Check database connections and external dependencies

Scale resources if needed

4. Recovery verification:

Monitor error rate decreasing below threshold

Verify service functionality.