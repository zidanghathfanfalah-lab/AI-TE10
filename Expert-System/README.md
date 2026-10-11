# SATRIA — Integrated Anamnesis and Referral Assistant System

Multi-Agent Medical Triage System via Band Architecture for early detection of endemic tropical diseases in Indonesia (Dengue, Typhoid, Malaria, ARI) and real-time optimization of healthcare facility queue workloads.

> **Why was SATRIA built?** Read [PHILOSOPHY.md](./PHILOSOPHY.md) — about the irony of the Indonesian healthcare system and why patients should be treated as customers.

## Architecture

```
Patient (Chat UI)
      │
      ▼
┌─────────────────┐
│ Anamnesis Agent │  ──► patient_context (Redis / Band)
└─────────────────┘
      │
      ▼
┌─────────────────┐
│ Clinical Expert │  ──► diagnosis_draft, triage_result, routing_result
└─────────────────┘
      │
      ▼
┌───────────────────┐
│Compliance Auditor │  ──► SOAP PMK 24/2022 -> PostgreSQL (RME)
└───────────────────┘
```

### Core Agents

| Agent | Responsibility |
|------|---------------|
| **Anamnesis Agent** | Direct natural chat with patient, gathering complaints, pain scale, and GPS location. Recruits specialist agents to the room once interview is complete. |
| **Clinical Expert Agent** | Clinical reasoning backbone using dynamic RAG (ChromaDB + LlamaIndex) on Kemenkes guidelines. Directs triage (P1/P2/P3) and handles fasyankes routing with queue reservation. |
| **Compliance Auditor Agent** | Assists the physician by checking drug interactions, generating standard SOAP drafts (PMK 24/2022), requesting doctor approval (/approve), and committing locked RME to PostgreSQL. |
| **Ingestion Agent (Satelite)** | Run-once or on-demand background worker that indexes Kemenkes PNPK documents into ChromaDB via LlamaIndex. |

## Tech Stack

- **Language**: Python 3.12+
- **AI**: Anthropic API (`claude-sonnet-4-6`)
- **Agent Communication**: `band-sdk` (asynchronous, context-sharing via chat room)
- **API**: FastAPI + Uvicorn
- **Database**: PostgreSQL 16 (permanent data store) + Redis 7 (session cache between agents)
- **ORM**: SQLAlchemy async + asyncpg
- **Migration**: Alembic
- **Frontend**: Astro (static) + Tailwind CSS + nginx
- **Containerization**: Docker Compose
- **Testing**: Pytest

## Directory Structure

```
bandrme/
├── agents/             # 3 Band agents and runners
│   ├── runners/        # Independent agent executable scripts
│   └── record.py       # Record synchronization helpers
├── band/               # Band Protocol configurations and handles
├── knowledge_base/     # Kemenkes PNPK — warning signs and references
├── models/             # Shared Pydantic schemas and database wrappers
├── api/                # FastAPI application — routes /patient and /doctor
├── db/
│   ├── engine.py       # SQLAlchemy async database connection
│   ├── models.py       # 23 ORM models (see Database Schema)
│   ├── session_store.py# Redis session manager
│   └── seed/           # Seed datasets and import scripts
├── alembic/            # Database schema migration files
├── config/             # Environment settings parser
├── frontend/           # Astro web app source code
└── tests/              # Test suites
```

## Setup

There are two ways to run SATRIA: **Full Docker** (for instant testing) and **Hybrid Mode** (highly recommended to save system resources).

---

### Method 1: Full Docker Compose (All Services in Container)

Best for quick evaluation without local environment setup.

```bash
# 1. Configure environment
cp .env.example .env
# Edit .env and fill in the required API keys

# 2. Run all services via Docker
docker compose up --build
```
*   **Backend API & Docs:** `http://localhost:8000/docs`
*   **Frontend Astro:** `http://localhost:4321`

---

### Method 2: Hybrid Mode (Highly Recommended — Saves Power & RAM)

Runs only the database (`db`) and cache (`redis`) services in Docker, while running the application, RAG, and agents directly on the host machine using a virtual environment (`.venv`).

#### 1. Run Database & Cache in Docker
```bash
docker compose up -d db redis
```

#### 2. Setup Local Virtual Environment
```bash
# Ensure you are using Python 3.12+
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

#### 3. Run Migrations & RAG Ingestion
```bash
# Apply schema migrations and seed initial data to PostgreSQL
PYTHONPATH=. python db/seed/scripts/seed_all.py

# Index medical PNPK documents to local ChromaDB
PYTHONPATH=. python agents/runners/ingestion_runner.py
```

#### 4. Run Backend & Frontend
*   **FastAPI Backend (Terminal 1):**
    ```bash
    PYTHONPATH=. python -m uvicorn api.main:app --reload --port 8000
    ```
*   **Astro Frontend (Terminal 2):**
    ```bash
    cd frontend
    npm install
    npm run dev
    ```

#### 5. Run Band Agent Runners (Terminal 3, 4, 5)
Run each agent runner script separately using the credentials from your environment or `agent_config.yaml`:
```bash
# Anamnesis Agent
PYTHONPATH=. python agents/runners/anamnesis_runner.py

# Clinical Expert Agent
PYTHONPATH=. python agents/runners/clinical_expert_runner.py

# Compliance Auditor Agent
PYTHONPATH=. python agents/runners/compliance_auditor_runner.py
```

## Database Schema

SATRIA uses PostgreSQL as its primary database with a structure closely resembling HL7 FHIR (the format used by Satu Sehat), making future integration with Satu Sehat seamless.

Total: **23 tables**, **22 enum types**, grouped into 6 domains.

### Group 1 — Administrative Areas (4 tables)

Hierarchy: Province -> Regency/City -> District -> Village

```
wilayah_provinsi (34 rows — seed provided)
wilayah_kabupaten_kota (514 rows — via import_wilayah.py)
wilayah_kecamatan (~7,000 rows — via import_wilayah.py)
wilayah_kelurahan_desa (~83,000 rows — via import_wilayah.py)
```

Key columns: `kode_bps` (standard BPS code), hierarchical foreign keys.

---

### Group 2 — Healthcare Facilities (6 tables) — maps to FHIR Organization + Location

```
organizations          — Hospitals, Puskesmas, Clinics, Pharmacies, Labs, etc.
locations              — GPS Coordinates + street addresses per facility
igd_capacities         — Real-time IGD bed availability (updated by agents)
queues                 — Daily queues per service unit (UNIQUE: org+unit+date)
operational_schedules  — Opening schedules per day
facility_services      — List of services available at the facility
```

Satu Sehat columns: `satu_sehat_org_id`, `satu_sehat_location_id`.

---

### Group 3 — Patients & Users (3 tables) — maps to FHIR Patient + Practitioner

```
patients           — Patient demographic data (NIK, BPJS, GPS home location)
users              — Doctors, nurses, admins (with STR & SIP credentials)
user_organizations — Many-to-many relationship mapping practitioners to facilities
```

---

### Group 4 — Encounters & RME (7 tables) — maps to FHIR Encounter + Clinical Resources

```
encounters             — Patient visit session (outpatient/inpatient/IGD/telemedicine)
conditions             — Diagnoses: ICD-10, AI-generated vs physician-confirmed
observations           — Vital signs & symptoms: LOINC codes, numeric values, abnormal flags
medication_statements  — Prescriptions and active medications (FHIR MedicationStatement)
allergies              — Active patient allergies (FHIR AllergyIntolerance)
medical_records        — Final RME in SOAP format (PMK 24/2022), immutable after locking
referrals              — Referral letters between healthcare facilities
```

RME uses the standard SOAP format:
- `S` (Subjective) — patient complaints reported during anamnesis
- `O` (Objective) — vital signs and physical examinations (stored in JSONB)
- `A` (Assessment) — final diagnosis verified by the doctor
- `P` (Plan) — actions, prescriptions, and referrals

---

### Group 5 — Band System Internals (4 tables)

```
sessions          — Active patient pipeline session (FK to patients + encounters)
band_events       — Audit trail of events passing through Band channels (BIGSERIAL)
agent_executions  — LLM call tracking logs: token usage, latency, and execution status
queue_slots       — Queue slots booked by routing tools
```

`band_events` and `agent_executions` utilize `BIGSERIAL` to support high log volumes.

---

### Group 6 — Clinical Reference Masters (3 tables)

```
icd10_codes    — ~60 relevant ICD-10 codes (seed provided)
loinc_codes    — ~35 LOINC codes for vital signs and symptoms (seed provided)
service_types  — Master list of service units / polyclinics
```

---

### Redis Session Store

In addition to PostgreSQL, active patient session states are cached in Redis as a hash:

```
Key: satria:session:{session_id}   TTL: 1 hour
Fields:
  chat_history      — conversation logs with anamnesis
  patient_context   — patient demographics & complaints from Anamnesis Agent
  diagnosis_draft   — technical diagnosis hypotheses from Clinical Expert
  triage_result     — calculated triage from Clinical Expert
  routing_result    — queue reservation details from Clinical Expert
```

Redis data is synchronized into the permanent PostgreSQL `sessions` and `medical_records` tables when the physician approves and locks the encounter.

---

### Seed Data

| File | Content | Import Method |
|------|-----|-----------|
| `db/seed/provinces.sql` | 34 Indonesian provinces | `psql $DB < provinces.sql` |
| `db/seed/icd10_subset.sql` | ~60 subset ICD-10 codes | `psql $DB < icd10_subset.sql` |
| `db/seed/loinc_subset.sql` | ~35 subset LOINC codes | `psql $DB < loinc_subset.sql` |
| `db/seed/scripts/import_wilayah.py` | ~83,000 village data from BPS | `python import_wilayah.py` |
| `db/seed/scripts/import_fasyankes.py` | RS Class A/B & capital Puskesmas | `python import_fasyankes.py` |

## Compliance

- **PMK No. 24 of 2022** — RME SOAP structure, immutable once locked by the doctor (`is_locked=True`)
- **HL7 FHIR** — Database schema maps directly to FHIR resources (Patient, Encounter, Condition, Observation, MedicationStatement, AllergyIntolerance), ready for Satu Sehat integration
- **CIA Triad** — Raw AI diagnostic hypotheses are kept inside internal Band logs and never exposed directly to patients without doctor approval

## KPIs

- Accuracy of identifying P1 warning signs (plasma leakage in Dengue, low SpO2 in ARI)
- Reduced patient waiting times at healthcare facilities for P3 triage cases
- Time efficiency of physical doctor anamnesis sessions
