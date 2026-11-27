# Route B handoff: hermes-pg-test scratch-pod test (plan section 7.5)

Everything in this file is for you to run on the laptop: kubectl against
cluster1, gh for the hermes-agent fork. The PR lands only the manifest
under apps/hermes/pg-scratch/ (outside the hermes Kustomization inventory,
so Flux never applies or prunes it); the apply/delete commands below are
hand-runs. Nothing here changes the running production hermes pod.

Live state verified 2026-11-26 (kagent, read-only): cnpg-hermes-state
healthy, 3/3 ready, PG 18.1, database hermesstate, failoverDelay 60,
primary cnpg-hermes-state-2; backup
cnpg-hermes-state-scheduled-20261126000000 completed; ExternalSecret
hermes-state-db Ready=True; its secret key names: HERMES_DATABASE_URL,
stateDbPass, stateDbUser; production hermes pod Running, 0 restarts.

Run every command from the biggs.dog repo root, with this PR's branch
(route-b/pg-scratch-pod) checked out. Record each command and its key
output: plan 7.6 says "Tested on cluster1" means steps 2-7 pass with the
command and key output recorded for each.

## Step 0 - build the test image (only if pg-port-52aa143 is not on Docker Hub yet)

Docker Hub checked 2026-11-26: only the two catalog-harness2 tags exist,
so the test image has to be built first. It builds the fork's
pg-backend-port tip (52aa14301f2eae8310f72790c0b9d6bb3df5ea77, the
pool-cascade fix) via the manual-dispatch build workflow, which can sit
queued on the self-hosted runner for a while (normal, not a fault). The
run's report job writes the pin line to its step summary on the run
page (not the job log); the digest command below records it directly.

```
gh workflow run dockerhub-custom-build.yml --repo shrinedogg/hermes-agent --ref build/dockerhub-catalog-harness2 -f commit=52aa14301f2eae8310f72790c0b9d6bb3df5ea77 -f tag=pg-port-52aa143
```

```
gh run list --repo shrinedogg/hermes-agent --workflow dockerhub-custom-build.yml --limit 3
```

Wait for the run to succeed, then confirm the tag exists (an HTTP 404 means it is not pushed yet):

```
curl -s https://hub.docker.com/v2/repositories/shrinedogg/hermes-agent/tags/pg-port-52aa143
```

Then fetch the tag's digest. It is the same Docker Hub endpoint the
report job reads; it errors until the build has pushed the tag:

```
curl -s https://hub.docker.com/v2/repositories/shrinedogg/hermes-agent/tags/pg-port-52aa143 | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])'
```

Record the digest as step 0's key output: the pin for the image line
is docker.io/shrinedogg/hermes-agent:pg-port-52aa143@<digest>.

## Step 1 - read-only checks (plan section 10 G)

Pass criteria: cluster healthy with 3/3 instances ready; a completed
cnpg-hermes-state backup; the ExternalSecret Ready; the secret carrying
the HERMES_DATABASE_URL key; the production hermes pod Running. The
describe line prints key names only, never values.

```
kubectl -n cnpg-system get cluster cnpg-hermes-state -o wide
```

```
kubectl -n cnpg-system get pods -l cnpg.io/cluster=cnpg-hermes-state -o wide
```

```
kubectl -n cnpg-system get scheduledbackups.postgresql.cnpg.io backups.postgresql.cnpg.io
```

```
kubectl -n hermes get pods -o wide
```

```
kubectl -n hermes get externalsecret hermes-state-db
```

```
kubectl -n hermes describe secret hermes-state-db
```

## Step 2 - apply the scratch deployments

One apply creates both writers (plan 7.5 steps 2 and 5): the
hermes-pg-test and hermes-pg-test-2 Deployments plus their own 1Gi
ceph-block PVCs hermes-pg-test-data / hermes-pg-test-2-data. The
production hermes pod is untouched: the test pods carry the
hermes-pg-test labels, so the production Service and HTTPRoute (both
selecting app.kubernetes.io/name=hermes) keep pointing at it.

```
kubectl -n hermes apply -f clusters/cluster1/kubernetes/apps/hermes/pg-scratch/hermes-pg-test.yaml
```

```
kubectl -n hermes rollout status deploy/hermes-pg-test
```

```
kubectl -n hermes rollout status deploy/hermes-pg-test-2
```

## Step 3 - let writer 1 start once, then set the provider and restart

The first start writes the default config into the fresh PVC. The tail
line shows that default config is there (the plan's first-start check).
Then append the persistence block and restart: the pod boots with
provider postgres + HERMES_DATABASE_URL.

```
kubectl -n hermes exec deploy/hermes-pg-test -- tail -n 3 /opt/data/config.yaml
```

```
kubectl -n hermes exec deploy/hermes-pg-test -- sh -c 'printf "persistence:\n  provider: postgres\n" >> /opt/data/config.yaml'
```

```
kubectl -n hermes rollout restart deployment/hermes-pg-test
```

```
kubectl -n hermes wait --for=condition=Ready pod -l app.kubernetes.io/name=hermes-pg-test --timeout=600s
```

## Step 4 - one round trip, then select the rows

The remember/recall pair is plan section C's real run: it must leave a
session row and its message rows in the new schema. Then select the
rows: the new schema exists, and it holds the session and its messages.
Note: plan section F's select line uses the column schemaname, which
does not exist in pg_namespace; the line below uses nspname instead
(verified against PostgreSQL 18.1).

```
kubectl -n hermes exec deploy/hermes-pg-test -- hermes chat -q 'Remember the word cobalt. Reply with only: ok'
```

```
kubectl -n hermes exec deploy/hermes-pg-test -- hermes chat -q 'What word did I ask you to remember?'
```

The recall should answer cobalt. Then the schema and the row counts (the
exec targets the current primary, so it keeps working after the step 6
failover):

```
kubectl -n cnpg-system exec $(kubectl -n cnpg-system get cluster cnpg-hermes-state -o jsonpath='{.status.currentPrimary}') -c postgres -- psql -U postgres -d hermesstate -c "select nspname from pg_namespace where nspname like 'hermes_%' order by 1"
```

The count line prints exactly one NOTICE like
NOTICE: schema hermes_default_1234567890ab sessions 4 messages 12 (one
schema for both writers, non-zero row counts):

```
kubectl -n cnpg-system exec $(kubectl -n cnpg-system get cluster cnpg-hermes-state -o jsonpath='{.status.currentPrimary}') -c postgres -- psql -U postgres -d hermesstate -c "do \$\$ declare s text; cs bigint; cm bigint; begin select nspname into s from pg_namespace where nspname like 'hermes_%%' order by 1 limit 1; if s is null then raise notice 'no hermes_%% schema found'; else execute 'select count(*) from ' || quote_ident(s) || '.sessions' into cs; execute 'select count(*) from ' || quote_ident(s) || '.messages' into cm; raise notice 'schema % sessions % messages %', s, cs, cm; end if; end \$\$;"
```

## Step 5 - the second writer

hermes-pg-test-2 already exists from step 2. It gets the same
persistence treatment (its own fresh PVC), then its own round trip.
Both writers run the same default profile from the same home path
string, so both resolve to one schema: this is the two-writers case
SQLite cannot give you. To stress true concurrency, run writer 1's
recall and writer 2's remember in two terminals at the same time; the
sequential lines below are enough as evidence.

```
kubectl -n hermes exec deploy/hermes-pg-test-2 -- tail -n 3 /opt/data/config.yaml
```

```
kubectl -n hermes exec deploy/hermes-pg-test-2 -- sh -c 'printf "persistence:\n  provider: postgres\n" >> /opt/data/config.yaml'
```

```
kubectl -n hermes rollout restart deployment/hermes-pg-test-2
```

```
kubectl -n hermes wait --for=condition=Ready pod -l app.kubernetes.io/name=hermes-pg-test-2 --timeout=600s
```

```
kubectl -n hermes exec deploy/hermes-pg-test-2 -- hermes chat -q 'Remember the word vermillion. Reply with only: ok'
```

```
kubectl -n hermes exec deploy/hermes-pg-test-2 -- hermes chat -q 'What word did I ask you to remember?'
```

The recall should answer vermillion. Re-run the two select lines from
step 4: still exactly one hermes_% schema, now holding both writers'
sessions and messages.

## Step 6 - failover

Delete the primary database pod. Allow at least the 60s failoverDelay
(the sleep is 75s for margin): CNPG recreates the deleted instance as a
replica and promotes a surviving one, and the write Service
cnpg-hermes-state-rw moves to the new primary. The next command after
the wait is a write through that Service: it must succeed.

```
kubectl -n cnpg-system delete pod $(kubectl -n cnpg-system get cluster cnpg-hermes-state -o jsonpath='{.status.currentPrimary}')
```

```
sleep 75
```

```
kubectl -n cnpg-system get cluster cnpg-hermes-state -o wide
```

The wide output shows the new primary (status currentPrimary), and the
deleted instance is back as a replica. Then the write through the moved
Service:

```
kubectl -n hermes exec deploy/hermes-pg-test -- hermes chat -q 'Reply with only: ok'
```

## Step 7 - kill test

Force-delete the scratch pod (mid-turn if you want the harder case:
start a hermes chat turn in one terminal and delete the pod while it is
in flight). The Deployment recreates it; the next turn must open the
store clean from PostgreSQL.

```
kubectl -n hermes delete pod -l app.kubernetes.io/name=hermes-pg-test --force --grace-period=0
```

```
kubectl -n hermes wait --for=condition=Ready pod -l app.kubernetes.io/name=hermes-pg-test --timeout=600s
```

```
kubectl -n hermes exec deploy/hermes-pg-test -- hermes chat -q 'What word did I ask you to remember?'
```

The answer should still be cobalt: the session survived a SIGKILL because
it lives in PostgreSQL, not in the pod.

## Step 8 - clean up

Delete both scratch Deployments and their two test PVCs (one delete -f
against the manifest), then drop the test schema. The schema name
carries a 12-hex digest suffix (hermes_default_ plus 12 hex digits), so
the drop line discovers it dynamically instead of hard-coding it.

```
kubectl -n hermes delete -f clusters/cluster1/kubernetes/apps/hermes/pg-scratch/hermes-pg-test.yaml
```

```
kubectl -n cnpg-system exec $(kubectl -n cnpg-system get cluster cnpg-hermes-state -o jsonpath='{.status.currentPrimary}') -c postgres -- psql -U postgres -d hermesstate -c "do \$\$ declare s text; begin select nspname into s from pg_namespace where nspname like 'hermes_%%' order by 1 limit 1; if s is null then raise notice 'no hermes_%% schema found'; else execute 'drop schema if exists ' || quote_ident(s) || ' cascade'; end if; end \$\$;"
```

Final state after cleanup: the production hermes pod untouched,
cnpg-hermes-state healthy, no hermes_% schema left in hermesstate, no
scratch Deployments or test PVCs in the hermes namespace.
