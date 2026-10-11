#!/bin/bash
set -e

echo "[backend] Starting initialization sequence..."

echo "[backend] Running database migrations..."
python -m alembic upgrade head
echo "[backend] ✓ Migrations complete"

echo "[backend] Seeding static reference data..."
python db/seed/scripts/seed_all.py
echo "[backend] ✓ Seed data complete"

echo "[backend] Building ChromaDB RAG index..."
python agents/runners/ingestion_runner.py
echo "[backend] ✓ RAG index complete"

echo "[backend] Starting Band agents..."
python agents/runners/anamnesis_runner.py &
python agents/runners/clinical_expert_runner.py &
python agents/runners/compliance_auditor_runner.py &
echo "[backend] ✓ Agents started"

echo "[backend] Starting API server..."
exec python -m uvicorn api.main:app --host 0.0.0.0 --port 8000 --log-level info
