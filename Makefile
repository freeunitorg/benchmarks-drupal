# Drupal application-server benchmarks: Apache+mod_php, nginx+PHP-FPM, FreeUnit.
#
# Everything runs on the perf host (default: the box in HARNESS run/lab.env,
# PERF_HOST). The box must be claimed and idle; jobs longer than 15 minutes wait
# for PERF_WINDOW. Published numbers only ever come from this host.

HOST        ?= pro4s-2
REMOTE_ROOT ?= /data/projects/benchmarks-drupal
RUNROOT     ?= $(REMOTE_ROOT)/run
SITE        ?= 11.4
JOB         ?= bench/jobs/02-front-anon-freeunit-vs-fpm-11.4.job

SSH = ssh $(HOST)
RSYNC = rsync -a --delete --exclude .git --exclude run ./ $(HOST):$(REMOTE_ROOT)/

help:
	@echo "make sync                 copy the repo to the perf host"
	@echo "make build                build the three runtime images on the host"
	@echo "make site SITE=11.4       build and install a Drupal site (demo_umami)"
	@echo "make bench JOB=...        run one bench job (claim, gate, cells, compare)"
	@echo "make ticks RUNTIME=... ARM=A|B TICKS=20   cron/queue arms"
	@echo "make report               render public/ (index + one page per family)"
	@echo "make pull                 copy results back from the host"

sync:
	$(RSYNC)
	$(SSH) "mkdir -p $(REMOTE_ROOT)/run"

build: sync
	$(SSH) "cd $(REMOTE_ROOT) && docker build -f docker/Dockerfile.freeunit -t drupal-bench-freeunit:1.37.0 ."
	$(SSH) "cd $(REMOTE_ROOT) && docker build -f docker/Dockerfile.php --target php-fpm -t drupal-bench-fpm:8.5 ."
	$(SSH) "cd $(REMOTE_ROOT) && docker build -f docker/Dockerfile.php --target apache -t drupal-bench-apache:8.5 ."
	$(SSH) "docker pull mariadb:10.11"

site: sync
	$(SSH) "cd $(REMOTE_ROOT) && RUNROOT=$(RUNROOT) scripts/site-build.sh $(SITE)"

bench: sync
	$(SSH) "cd $(REMOTE_ROOT) && RUNROOT=$(RUNROOT) bench/run.sh $(JOB)"

ticks: sync
	$(SSH) "cd $(REMOTE_ROOT) && RUNROOT=$(RUNROOT) bench/tick.sh $(RUNTIME) $(ARM) $(TICKS)"

report:
	python3 report/render.py results public/index.html

pull:
	rsync -a --exclude results.tsv $(HOST):$(REMOTE_ROOT)/run/ ./run/ 2>/dev/null || true
	rsync -a $(HOST):$(REMOTE_ROOT)/results/ ./results/ 2>/dev/null || true

.PHONY: help sync build site bench ticks report pull
