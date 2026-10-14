# Deploy di QuizArena

Ogni macchina ("VM") esegue un nodo Erlang (release OTP) e un Tomcat.
I nodi Erlang formano un cluster con Mnesia replicata; Nginx, su una delle
macchine, e' l'unico punto di ingresso e distribuisce HTTP e WebSocket sui
Tomcat.

```
Browser ──► Nginx (URL unico) ──► Tomcat vm1 | vm2 | vm3
Tomcat vmX ──Jinterface──► nodo Erlang locale (fallback sugli altri)
Erlang quizarena@vm1..3: cluster, global, Mnesia replicata, elezione Bully
```

## Simulazione locale con Docker Compose

Dalla radice del repository:

```
docker compose -f deploy/docker-compose.yml up -d --build
```

Applicazione: http://localhost:8080/

I dati Mnesia di ogni VM stanno nei volumi `deploy_vmN-data`
(`docker compose -f deploy/docker-compose.yml down -v` li cancella).

### Comandi utili per la demo

```
# Stato del cluster (da qualunque VM)
docker exec deploy-vm1-1 /opt/quizarena/bin/quizarena eval "mnesia:system_info(running_db_nodes)."
docker exec deploy-vm1-1 /opt/quizarena/bin/quizarena eval "quizarena_election:leader()."

# Nodo che ospita una stanza (PIN scritto come lista di caratteri, es. "123456")
docker exec deploy-vm1-1 /opt/quizarena/bin/quizarena eval "node(global:whereis_name({room, [49,50,51,52,53,54]}))."

# Guasto di una macchina e suo rientro
docker kill deploy-vm2-1
docker start deploy-vm2-1

# Log di una VM (nodo Erlang e Tomcat)
docker compose -f deploy/docker-compose.yml logs -f vm2
```

Da Git Bash su Windows anteporre `MSYS_NO_PATHCONV=1` ai comandi `docker exec`.

### Cosa succede quando una VM cade

1. La distribuzione Erlang dichiara il nodo down dopo circa 8-10 s
   (`net_ticktime 8` in `config/sys.config`).
2. Se era il leader, i superstiti eseguono l'elezione Bully
   (`src/quizarena_election.erl`) e vince il nodo attivo piu' in alto in
   `QUIZARENA_CLUSTER_NODES`.
3. Il leader rilancia le stanze del nodo caduto a partire dagli snapshot
   replicati in Mnesia, con giocatori, punteggi, risposte gia' date e tempo
   residuo del round.
4. I client collegati ad altri Tomcat ricevono `room_recovered` senza
   perdere la connessione; quelli collegati al Tomcat caduto si
   riconnettono tramite Nginx e rientrano senza rifare il login (cookie
   `QA_AUTH` firmato, valido su ogni Tomcat).

Misure sul cluster Compose: stanza ripristinata e client rientrati in 3-6 s
dalla caduta, sia per una VM qualsiasi sia per il leader.

## Deploy su macchine reali

Su ogni macchina, con Docker installato, si usa la stessa immagine con la
rete dell'host, cosi' nomi e porte dei nodi Erlang coincidono con quelli
della macchina:

```
docker build -t quizarena-vm -f deploy/Dockerfile .

docker run -d --name quizarena --network host --hostname vm1 \
  -e QUIZARENA_CLUSTER_NODES=quizarena@vm1,quizarena@vm2,quizarena@vm3 \
  -e ERLANG_COOKIE=<segreto condiviso> \
  -e QUIZARENA_AUTH_SECRET=<segreto condiviso> \
  -v quizarena-data:/opt/quizarena/data \
  quizarena-vm
```

(`--hostname` deve corrispondere al nome breve della macchina usato in
`QUIZARENA_CLUSTER_NODES`.)

Requisiti di rete:

- i nomi `vm1`, `vm2`, `vm3` devono risolversi sugli indirizzi delle
  macchine (DNS o `/etc/hosts` su ognuna);
- fra le macchine devono essere aperte le porte 4369 (epmd), 9100
  (distribuzione Erlang, fissata in `config/vm.args.src`) e 8080 (Tomcat);
- verso l'esterno serve solo la porta di Nginx;
- gli orologi delle macchine devono essere sincronizzati (NTP): la scadenza
  dei round ripristinati e' calcolata sul tempo di sistema.

Nginx, su una delle macchine:

```
docker run -d --name quizarena-nginx -p 80:80 \
  -v $PWD/deploy/nginx.conf:/etc/nginx/conf.d/default.conf:ro nginx:1.27-alpine
```

con gli indirizzi delle macchine negli `upstream` di `deploy/nginx.conf`
(su rete host i nomi `vmN` devono essere risolvibili anche dal container).

## Limiti noti

- Nginx e' un single point of failure: se cade la sua macchina
  l'applicazione non e' raggiungibile, anche se il cluster resta integro.
- Partizioni di rete: Bully e Mnesia assumono un sistema sincrono, in cui un
  nodo che non risponde e' davvero guasto. Con la rete partizionata due
  gruppi di nodi possono eleggere ciascuno un leader e Mnesia segnala
  `inconsistent_database`; la riconciliazione e' manuale.
- Una stanza viene ripristinata al massimo 3 volte; oltre, la partita viene
  annullata.
