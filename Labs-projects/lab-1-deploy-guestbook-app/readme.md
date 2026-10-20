**Note: This Lab should be done in the EKS cluster**

## Lab: Deploying PHP Guestbook application with Redis

### Description
A Guestbook App is a simple web application where users can submit and view messages, similar to leaving comments in a guestbook.

#### How It Works
- Users visit the web page
- They enter a message (like "Hello from John!")
- The message is saved in a database (in this case, Redis)
- Other users can see all messages

#### Why use Redis?
Redis (Remote Dictionary Server) is an open-source, **in-memory** data store making it a great choice for storing guestbook messages. Here’s why:

- **Speed:** Since Redis stores data in memory (RAM), it is much faster than traditional databases like MySQL or PostgreSQL. This makes reading and writing messages almost instant.
- **Simplicity:** Redis uses a key-value store, making it easy to save and retrieve guestbook messages without complex queries.
- **Scalability:** Redis supports replication (Leader-Follower setup), so it can handle more users as the guestbook grows.
- **Real-time Updates:** Redis supports Pub/Sub messaging, which allows instant updates without refreshing the page.
- **Data Persistence (Optional):** While Redis is in-memory, it can also persist data to disk, ensuring messages are not lost on restart.

#### Architecture Overview
- **Redis Master:** Handles write operations and replicates data to followers.
- **Redis Follower:** Reads data replicated from the master and handles read operations.
- **Frontend Application:** A simple web interface that interacts with Redis (reads from the follower, writes to the master).

![guestbook-architecture](guestbook-architecture.PNG)


### Lab Steps

#### Deploy Redis leader

- Create and apply a Redis leader deployment (single replica) and the Redis leader service to expose the leader for follower replication and frontend access.
- Use the file: `01-redis-leader-deployment-service.yaml`
- Notice that the leader and follower Deployments both carry `app: redis`, so each selector **also** matches on `role` and `tier`. Two Deployments with overlapping selectors would fight over each other's pods.

Apply the file
```bash
kubectl apply -f 01-redis-leader-deployment-service.yaml
kubectl get deploy,svc,pods
```

#### Deploy Redis Follower

- Create Redis follower deployment that replicate data from the master.
- Connect the follower pods to the master using replication settings.
- Apply the file `02-redis-follower-deployment-service.yaml`
```bash
kubectl apply -f 02-redis-follower-deployment-service.yaml
kubectl get deploy,svc,pods
```

#### Deploy the Frontend Application

Create and apply the frontend ConfigMap, deployment and service for the php app. The ConfigMap `frontend-config` holds `GET_HOSTS_FROM=dns`, loaded into the container with `envFrom` (see chapter 10): the app then finds Redis through the Service DNS names `redis-leader` and `redis-follower`.

Apply the file `03-frontend-deployment-service.yaml`
```bash
kubectl apply -f 03-frontend-deployment-service.yaml
kubectl get deploy,svc,pods
```

#### Test the Deployment

The frontend is exposed by the Ingress `frontend` at **https://guestbook.afriqhome.com** (ALB + ACM certificate + DNS record created by ExternalDNS: prerequisites from chapter 08; replace the domain with yours in `03-frontend-deployment-service.yaml`).
```bash
kubectl get ingress frontend
kubectl logs -n external-dns deploy/external-dns | grep guestbook
# wait for "CREATE guestbook.afriqhome.com", then 1 to 3 minutes
```
Open https://guestbook.afriqhome.com, type a message and click Submit.

**Note: Remember to delete the Ingress (it is a real ALB) when you are done: see Clean up.**


#### Scale the frontend deployment
```bash
kubectl scale deployment frontend --replicas=4
kubectl get pods
kubectl scale deployment frontend --replicas=1
kubectl get pods
```
**Exercise:** verify replication. Write a message in the web page, then read the Redis key `guestbook` on the leader and on a follower: both return the same value.
```bash
LEADER=$(kubectl get pod -l role=leader -o name)
FOLLOWER=$(kubectl get pod -l role=follower -o name | head -1)
kubectl exec $LEADER -- redis-cli get guestbook
kubectl exec $FOLLOWER -- redis-cli get guestbook
kubectl exec $FOLLOWER -- redis-cli info replication | grep -E "role|master_host|master_link_status"
# role:slave  master_host:redis-leader  master_link_status:up
```

### Expected Outcome
By the end of this lab, you will have a functional Redis replication setup with a frontend interacting with it. This setup is commonly used to improve scalability and performance in real-world applications.

![guestbook app](guestbook.png)

### Clean up

You can use labels to deploy multiple resources with one command. Run the following commands to delete all pods, deployments and services we disployed:
```bash
kubectl delete deployment -l app=redis
kubectl delete service -l app=redis
kubectl delete -f 03-frontend-deployment-service.yaml
```

