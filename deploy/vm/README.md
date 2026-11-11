# Deploy su VM reali

Deploy di QuizArena sui tre container Ubuntu 24.04 del corso, senza
Docker. Stessa architettura della simulazione con Docker Compose
(`deploy/README.md`): ogni VM esegue un nodo Erlang e un Tomcat, Nginx
su VM1 e' l'unico punto di ingresso.

| VM  | IP       | Servizi                       |
|-----|----------|-------------------------------|
| VM1 | 10.2.1.3 | `quizarena@10.2.1.3`, Tomcat, Nginx |
| VM2 | 10.2.1.4 | `quizarena@10.2.1.4`, Tomcat  |
| VM3 | 10.2.1.5 | `quizarena@10.2.1.5`, Tomcat  |

Si usano gli IP al posto dei nomi host perche' `/etc/hosts` dei container
non e' modificabile. Porte: epmd 4369, distribuzione Erlang 9100,
Tomcat 8080, Nginx 80. Applicazione: http://10.2.1.3/ (VPN attiva).

## File

| File | Destinazione | Ruolo |
|------|--------------|-------|
| `start.sh` | `/opt/quizarena/start.sh` (tutte) | Avvia il nodo Erlang con `-name quizarena@<IP>` |
| `setenv.sh` | `/usr/share/tomcat10/bin/setenv.sh` (tutte) | Variabili d'ambiente lette dalla web app |
| `quizarena.conf` | `/etc/nginx/sites-available/` (VM1) | Bilanciamento `least_conn` sui tre Tomcat |
| `lb-test.sh` | `/opt/quizarena/lb-test.sh` (VM1) | Verifica del bilanciamento |

`start.sh` rileva l'IP locale, genera `vm.args` con nomi lunghi
(`config/vm.args.src` usa `-sname`, adatto solo a un singolo host) e
scrive la lista dei nodi in `sys.config`. `setenv.sh` usa `export` perche'
la web app legge le impostazioni con `System.getenv`.

## Installazione (una volta, su ogni VM)

```
# rebar3 di apt (3.19) non funziona con OTP 28
apt remove -y rebar3
wget -O /usr/local/bin/rebar3 https://s3.amazonaws.com/rebar3/rebar3
chmod +x /usr/local/bin/rebar3

apt install -y tomcat10 gettext-base          # VM1 anche: nginx

# il JDK di SDKMAN sotto /root non e' leggibile dall'utente tomcat
cp -r /root/.sdkman/candidates/java/25.0.1-open /opt/java-25
chmod -R 755 /opt/java-25

# progetto in /opt/quizarena, poi:
cd /opt/quizarena && rebar3 release
cd web && mvn clean package -DskipTests
cp target/quizarena.war /var/lib/tomcat10/webapps/

cp deploy/vm/start.sh /opt/quizarena/start.sh
cp deploy/vm/setenv.sh /usr/share/tomcat10/bin/setenv.sh
chmod +x /opt/quizarena/start.sh /usr/share/tomcat10/bin/setenv.sh
```

Solo VM1:

```
cp deploy/vm/quizarena.conf /etc/nginx/sites-available/
ln -sf /etc/nginx/sites-available/quizarena.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
cp deploy/vm/lb-test.sh /opt/quizarena/ && chmod +x /opt/quizarena/lb-test.sh
nginx -t && systemctl restart nginx
```

## Avvio

Il nodo Erlang non e' un servizio di sistema: dopo un riavvio dei
container va rilanciato a mano, prima di Tomcat.

```
/opt/quizarena/start.sh        # VM1, poi VM2, poi VM3 (VM1 e' il seed Mnesia)
systemctl restart tomcat10     # su tutte
systemctl start nginx          # VM1
```

`start.sh` e' idempotente (ferma l'istanza precedente) e stampa lo stato
del cluster: con tutte e tre le VM avviate `running_db_nodes` contiene i
tre nodi e il leader e' `quizarena@10.2.1.5`.

## Verifiche

```
# Bilanciamento (da VM1)
/opt/quizarena/lb-test.sh 30
#   10.2.1.3:8080   10
#   10.2.1.4:8080   10
#   10.2.1.5:8080   10

# Tomcat collegato al nodo Erlang (su ogni VM)
grep "gateway reachable" /var/log/tomcat10/localhost.*.log | tail -1
```

L'intestazione `X-Upstream` indica il Tomcat che ha servito ogni
risposta ed e' visibile anche dal browser (strumenti sviluppatore, Rete).

## Log

| Componente | Posizione |
|------------|-----------|
| Nodo Erlang | `/var/log/quizarena-erlang.log` |
| Tomcat | `/var/log/tomcat10/catalina.<data>.log`, `localhost.<data>.log` |
| Accessi Tomcat | `/var/log/tomcat10/localhost_access_log.<data>.txt` |
| Nginx | `/var/log/nginx/access.log`, `error.log` |

I dati Mnesia stanno in `_build/default/rel/quizarena/data/mnesia`:
cancellare `_build` li elimina.
