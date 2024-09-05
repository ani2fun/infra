To integrate the NGINX configuration on your `cloud-vm` with your local Kubernetes NGINX Ingress Controller, you'll need to make some adjustments to ensure that traffic is correctly proxied from the `cloud-vm` to the NGINX Ingress Controller in your Kubernetes cluster.

### Key Considerations:
1. **SSL Termination**: The SSL certificates should be managed either on the `cloud-vm` or at the Kubernetes level (via the NGINX Ingress Controller), but not both, to avoid conflicts.
2. **Proxy Configuration**: Ensure that the NGINX on `cloud-vm` correctly forwards traffic to the Ingress Controller on the Kubernetes cluster.
3. **Avoid SSL Redirection Loops**: Properly manage SSL redirection to prevent loops.

### Configuration Options:

#### Option 1: SSL Termination on `cloud-vm`
In this setup, `cloud-vm` handles SSL termination, and traffic is proxied as HTTP to the Kubernetes NGINX Ingress Controller.

1. **Keep SSL Configuration on `cloud-vm`**: Your current SSL configuration remains as-is.

2. **Proxy to HTTP in Kubernetes**:
   Modify the `proxy_pass` directive to point to the HTTP port of your NGINX Ingress Controller on Kubernetes:

   ```nginx
   upstream k8s_cluster {
     server 10.0.0.3:32080;  # Use the HTTP NodePort
   }
   ```

3. **Ensure NGINX Ingress Controller Accepts HTTP**:
    - Ensure your Ingress resources in Kubernetes don’t enforce SSL (i.e., remove `tls` sections and SSL-related annotations like `nginx.ingress.kubernetes.io/force-ssl-redirect`).

4. **Nginx Configuration on `cloud-vm`**:
   Here's your updated NGINX configuration:

   ```nginx
   user nginx;
   worker_processes auto;
   error_log /var/log/nginx/error.log;
   pid /run/nginx.pid;

   include /usr/share/nginx/modules/*.conf;

   events {
       worker_connections 1024;
   }

   http {
       log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                         '$status $body_bytes_sent "$http_referer" '
                         '"$http_user_agent" "$http_x_forwarded_for"';

       access_log  /var/log/nginx/access.log  main;

       sendfile            on;
       keepalive_timeout   65;
       types_hash_max_size 4096;

       include             /etc/nginx/mime.types;
       default_type        application/octet-stream;

       include /etc/nginx/conf.d/*.conf;

       # HTTP redirect to HTTPS
       server {
           listen      80 default_server;
           listen [::]:80 default_server;
           server_name *.kakde.eu;
           access_log  off;
           error_log   off;
           return 301 https://$host$request_uri;
       }

       upstream k8s_cluster {
           server 10.0.0.3:32080;  # HTTP NodePort of Ingress Controller
       }

       server {
           listen 443 ssl http2;
           listen [::]:443 ssl http2;

           server_name *.kakde.eu;

           ssl_trusted_certificate /etc/nginx/ssl/kakde.eu/kakde.eu.fullchain.cer;
           ssl_certificate /etc/nginx/ssl/kakde.eu/kakde.eu.fullchain.cer;
           ssl_certificate_key /etc/nginx/ssl/kakde.eu/kakde.eu.key;
           ssl_dhparam /etc/nginx/ssl/kakde.eu/dhparams.pem;

           ssl_session_timeout 1d;
           ssl_session_cache shared:NginxSSL:10m;
           ssl_protocols TLSv1.2 TLSv1.3;
           ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
           ssl_prefer_server_ciphers off;

           add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
           add_header X-Content-Type-Options "nosniff" always;
           add_header X-Frame-Options "SAMEORIGIN" always;
           add_header X-Xss-Protection "1; mode=block" always;
           add_header Referrer-Policy  strict-origin-when-cross-origin always;

           ssl_stapling on;
           ssl_stapling_verify on;

           resolver 1.1.1.1 8.8.8.8 valid=300s;
           resolver_timeout 5s;

           location / {
               proxy_pass http://k8s_cluster;
               proxy_set_header Host $host;
               proxy_set_header X-Real-IP $remote_addr;
               proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
               proxy_set_header X-Forwarded-Proto $scheme;
           }

           access_log /var/log/nginx/kakde.eu_access.log;
           error_log  /var/log/nginx/kakde.eu_error.log;
       }
   }
   ```

#### Option 2: SSL Termination on Kubernetes
In this setup, the NGINX Ingress Controller in Kubernetes handles SSL termination, and traffic from `cloud-vm` is passed as HTTPS.

1. **Remove SSL Configuration from `cloud-vm`**: Simplify the NGINX configuration on `cloud-vm` to only proxy traffic without SSL termination.

2. **Ensure Kubernetes Ingress Handles SSL**:
    - Keep the `tls` sections in your Ingress resources.
    - Configure NGINX Ingress Controller to handle SSL with your wildcard certificate.

3. **Nginx Configuration on `cloud-vm`**:
   Here’s how to modify the NGINX configuration on `cloud-vm`:

   ```nginx
   user nginx;
   worker_processes auto;
   error_log /var/log/nginx/error.log;
   pid /run/nginx.pid;

   include /usr/share/nginx/modules/*.conf;

   events {
       worker_connections 1024;
   }

   http {
       log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                         '$status $body_bytes_sent "$http_referer" '
                         '"$http_user_agent" "$http_x_forwarded_for"';

       access_log  /var/log/nginx/access.log  main;

       sendfile            on;
       keepalive_timeout   65;
       types_hash_max_size 4096;

       include             /etc/nginx/mime.types;
       default_type        application/octet-stream;

       include /etc/nginx/conf.d/*.conf;

       # HTTP redirect to HTTPS
       server {
           listen      80 default_server;
           listen [::]:80 default_server;
           server_name *.kakde.eu;
           access_log  off;
           error_log   off;
           return 301 https://$host$request_uri;
       }

       upstream k8s_cluster {
           server 10.0.0.3:32443;  # HTTPS NodePort of Ingress Controller
       }

       server {
           listen 443 ssl http2;
           listen [::]:443 ssl http2;

           server_name *.kakde.eu;

           location / {
               proxy_pass https://k8s_cluster;
               proxy_set_header Host $host;
               proxy_set_header X-Real-IP $remote_addr;
               proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
               proxy_set_header X-Forwarded-Proto $scheme;
           }

           access_log /var/log/nginx/kakde.eu_access.log;
           error_log  /var/log/nginx/kakde.eu_error.log;
       }
   }
   ```

### Summary:

- **Option 1**: SSL termination happens on the `cloud-vm`, and traffic is proxied as HTTP to Kubernetes.
- **Option 2**: SSL termination happens in Kubernetes, and traffic is proxied as HTTPS from `cloud-vm` to Kubernetes.

In both cases, ensure that SSL termination only happens in one place to avoid conflicts and redirect loops. Adjust the `nginx.conf` based on where you choose to handle SSL.

### **Option 1: SSL Termination on `cloud-vm`**

#### **How It Works:**
In this setup, the SSL certificates are managed and terminated at the `cloud-vm`. The traffic between the client and the `cloud-vm` is encrypted (HTTPS), but the traffic from the `cloud-vm` to the Kubernetes NGINX Ingress Controller is sent as plain HTTP.

#### **Advantages:**

1. **Centralized SSL Management:**
    - SSL certificates are managed in one place (`cloud-vm`), making it easier to handle certificate renewals, updates, and monitoring.

2. **Simplified Kubernetes Configuration:**
    - No need to configure or manage SSL certificates within Kubernetes. This simplifies the Ingress setup and reduces the complexity of the Kubernetes environment.

3. **Reduced Overhead in Kubernetes:**
    - SSL termination offloaded to `cloud-vm` reduces the processing overhead on the Kubernetes nodes, potentially improving performance and scalability within the cluster.

4. **Consistent SSL Configuration:**
    - The SSL configuration (ciphers, protocols, etc.) is consistent across all services managed by `cloud-vm`, providing a uniform security posture.

5. **Compatibility with Legacy Applications:**
    - If the backend services or the Kubernetes environment are not fully optimized for handling SSL traffic, this option allows them to operate over HTTP while still securing client communications.

#### **Disadvantages:**

1. **Potential Security Risk:**
    - Traffic between `cloud-vm` and Kubernetes is unencrypted (HTTP). This could be a security risk if the communication is not isolated (e.g., within a secure network or VPN tunnel).

2. **Single Point of Failure:**
    - `cloud-vm` becomes a critical point for SSL termination. If it fails or is compromised, all SSL termination for services managed by it could be affected.

3. **Limited End-to-End Encryption:**
    - Since SSL is terminated at the `cloud-vm`, there is no end-to-end encryption between the client and the Kubernetes services, which could be a concern in environments where security is paramount.

4. **Complexity in Scaling:**
    - If you need to scale SSL termination, you might need to introduce more complexity at the `cloud-vm` level (e.g., load balancing multiple `cloud-vm` instances).

---

### **Option 2: SSL Termination on Kubernetes**

#### **How It Works:**
In this setup, the SSL certificates are managed and terminated within the Kubernetes cluster by the NGINX Ingress Controller. The traffic between the client and the NGINX Ingress Controller is encrypted (HTTPS), and the `cloud-vm` simply forwards the traffic without decrypting it.

#### **Advantages:**

1. **End-to-End Encryption:**
    - SSL termination at the Kubernetes level provides true end-to-end encryption from the client to the backend services within the cluster, improving security.

2. **Reduced Load on `cloud-vm`:**
    - Since the `cloud-vm` is only forwarding traffic and not handling SSL termination, it has less processing overhead, which might improve its performance and reduce the risk of it becoming a bottleneck.

3. **Flexibility in Certificate Management:**
    - Kubernetes can manage multiple SSL certificates, each tied to specific Ingress resources. This provides more flexibility in handling multi-domain or multi-service environments.

4. **Scalability:**
    - SSL termination is distributed across the Kubernetes cluster, which can scale more easily with increased traffic and workloads.

5. **Improved Security Posture:**
    - Since the traffic remains encrypted all the way to the Ingress Controller, this option is more secure, especially in environments where internal network security is a concern.

#### **Disadvantages:**

1. **Increased Complexity:**
    - SSL management is now part of the Kubernetes environment, which adds complexity to the Ingress configuration, certificate management, and debugging.

2. **Increased Overhead on Kubernetes:**
    - SSL termination adds processing overhead on the Kubernetes nodes running the NGINX Ingress Controller, potentially impacting performance if not properly managed.

3. **Distributed SSL Configuration:**
    - SSL settings (ciphers, protocols) must be managed within Kubernetes, potentially leading to inconsistencies if different Ingress controllers or configurations are used.

4. **Certificate Management Complexity:**
    - Managing SSL certificates within Kubernetes might require additional tools (e.g., cert-manager) to automate renewals and updates, increasing operational complexity.

5. **Potential Latency:**
    - If the Kubernetes cluster is geographically distant from the `cloud-vm`, there might be some latency added due to SSL termination occurring within the cluster.

---

### **Choosing Between Option 1 and Option 2:**

- **Option 1 (SSL Termination on `cloud-vm`) is better suited if:**
    - You prefer centralized SSL management.
    - Your Kubernetes environment is not optimized for SSL termination.
    - You are operating within a trusted internal network where HTTP communication between `cloud-vm` and Kubernetes is acceptable.
    - You want to offload the SSL termination workload from Kubernetes.

- **Option 2 (SSL Termination on Kubernetes) is better suited if:**
    - Security is a top priority, and end-to-end encryption is required.
    - You want a more scalable solution that integrates closely with Kubernetes.
    - Your Kubernetes environment is already set up to handle SSL certificates and traffic efficiently.
    - You want to reduce the processing burden on `cloud-vm` and distribute it across the Kubernetes cluster.

Ultimately, the choice between these options depends on your specific requirements for security, performance, and operational complexity.