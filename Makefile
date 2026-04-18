.PHONY: up down build logs status ps clean restart

up:
	docker compose up -d --build
	@echo ""
	@echo "  Portal  → http://localhost:8000"
	@echo "  Grafana → http://localhost:3100  (admin/admin)"
	@echo ""

down:
	docker compose down

build:
	docker compose build --no-cache

logs:
	docker compose logs -f

logs-portal:
	docker compose logs -f portal

status:
	docker compose ps

ps: status

restart:
	docker compose restart

clean:
	docker compose down -v --remove-orphans
	@echo "All containers and volumes removed."

# Run a quick smoke test from host (requires k6 installed locally)
smoke:
	k6 run --out influxdb=http://localhost:8086/k6 scripts/smoke-test.js
