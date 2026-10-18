# Smart Parking System - DBMS Project Backend & Operations Report

**Project Title:** ABC Mall Smart Parking Management System  
**Database:** PostgreSQL (Supabase BaaS)  
**Frontend:** HTML5, CSS3, Vanilla JavaScript (Supabase JS SDK v2)  
**Live URL:** [https://jeevan-reddy-codee.github.io/Smart-Parking-System/](https://jeevan-reddy-codee.github.io/Smart-Parking-System/)  
**GitHub Repository:** [https://github.com/jeevan-reddy-codee/Smart-Parking-System](https://github.com/jeevan-reddy-codee/Smart-Parking-System)

---

## 1. Executive Summary
This document provides an end-to-end breakdown of the database architecture, backend execution flow, data storage design, and the exact mapping between frontend interactive elements (buttons/forms) and backend PostgreSQL functions, views, triggers, and Row Level Security (RLS) policies.

---

## 2. Interactive Button-to-Database Mapping Table

The following table details every user action in the application, the triggered frontend JavaScript function, and the corresponding PostgreSQL command or Stored Procedure executed in the database:

| # | UI Element / Button | Location | JavaScript Trigger | Backend Action (SQL / RPC) | Database Effect |
|---|---------------------|----------|--------------------|----------------------------|-----------------|
| **1** | **"Continue with Google"** | Sign In Modal | `db.auth.signInWithOAuth()` | Supabase Auth + Trigger `on_signup` | Creates user in `auth.users`; trigger fires `handle_new_user()` inserting a new row into `public.profiles`. |
| **2** | **"Create account"** | Sign In Modal | `db.auth.signUp()` | `supabase.auth.signUp()` &rarr; Trigger `on_signup` | Creates credential record in `auth.users`, automatically populates `public.profiles(id, name, role='driver')`. |
| **3** | **"Sign in"** | Sign In Modal | `db.auth.signInWithPassword()` | `supabase.auth.signInWithPassword()` | Generates JWT session token; client fetches user profile via `SELECT * FROM profiles WHERE id = auth.uid()`. |
| **4** | **"Sign out"** | Header | `db.auth.signOut()` | `supabase.auth.signOut()` | Clears JWT session from local storage; resets client state to guest viewer. |
| **5** | **Parking Slot Bay** | Parking Map | `bay(s, k)` &rarr; `S.sel = s.id` | Queries `slot_timeline` & `pricing` | Retrieves booked time intervals and hourly rate for the selected slot. |
| **6** | **"Book this slot"** | Slot Details Card | `bookM(id)` | None (UI state) | Opens the booking modal pre-filled with the selected slot's ID and allowed vehicle types. |
| **7** | **"Confirm booking"** | Booking Modal | `book(e, id)` | **`RPC book_slot(...)`** | Executes stored procedure: verifies availability, locks slot (`FOR UPDATE`), checks no time collisions, and inserts row into `bookings`. |
| **8** | **"Enter"** (Gate Entry) | Parking Bay (When active) | `run(db.rpc('enter_booking', {p_id}))` | **`RPC enter_booking(p_id)`** | Validates entry window (`now() >= start_time`), sets `status = 'active'`, and records `entered_at = now()`. |
| **9** | **"Exit"** (Gate Exit / Bill) | Parking Bay (When parked) | `exitB(id)` | **`RPC exit_booking(p_id)`** | Computes duration, calculates base and overtime penalty fees, updates `status = 'completed'`, records `exited_at = now()`, and returns total bill amount. |
| **10** | **"Cancel"** | My Bookings Tab | `cancelB(b.id)` | **`RPC cancel_booking(p_id)`** | If cancelled `< 1 hour` before start, charges 1 hour penalty fee; marks booking `status = 'cancelled'`. |
| **11** | **"Extend"** | My Bookings Tab | `extM(id, cur)` &rarr; `ext(e, id)` | **`RPC extend_booking(p_id, p_end)`** | Checks for overlapping future bookings on that slot; logs previous/new end time in `booking_extensions`, updates `end_time` in `bookings`. |
| **12** | **"Save vehicle"** | Add Vehicle Modal | `addV(e)` | `INSERT INTO vehicles(...)` | Inserts plate and type into `vehicles` table linked to `auth.uid()`. Enforced by `UNIQUE(user_id, plate)`. |
| **13** | **"Remove"** (Vehicle) | My Vehicles Tab | `db.from('vehicles').delete()` | `DELETE FROM vehicles WHERE id = ...` | Deletes vehicle record. Protected by RLS policy `v_all` ensuring users can only delete their own vehicles. |
| **14** | **"Save"** (Pricing) | Admin Tab | `savePrice(vehicle_type)` | `UPDATE pricing SET rate_normal=..., rate_open=... WHERE vehicle_type=...` | Updates hourly rates in `pricing`. Protected by RLS policy checking `is_admin()`. |
| **15** | **Slot Toggle (On/Off)** | Admin Tab | `db.from('slots').update({active: !s.active})` | `UPDATE slots SET active = ... WHERE id = ...` | Toggles maintenance/availability flag in `slots` table. Restricted to admin role. |
| **16** | **"Mark paid"** | Admin Tab (Toll Desk) | `db.from('bookings').update({paid: true})` | `UPDATE bookings SET paid = true WHERE id = ...` | Admin marks bill as collected at the exit toll gate. Restricted to admin role. |

---

## 3. Database Architecture & Schema Design

The backend runs on **PostgreSQL** relational database. The schema implements standard Boyce-Codd Normal Form (BCNF) principles, referential integrity constraints, and temporal tracking.

```
                    +---------------------------+
                    |        auth.users         |
                    |  (Supabase Auth Engine)   |
                    +-------------+-------------+
                                  | 1:1
                                  v
+------------------+ 1:N    +---------------------------+
|     vehicles     |<-------|         profiles          |
|------------------|        |---------------------------|
| id (PK)          |        | id (PK, FK -> auth.users) |
| user_id (FK)     |        | name                      |
| plate            |        | name_confirmed            |
| type (car/bike)  |        | role ('driver' / 'admin') |
+------------------+        +-------------+-------------+
                                          | 1:N
                                          v
+------------------+ 1:N    +---------------------------+    N:1    +------------------+
|      slots       |<-------|         bookings          |--------->|     pricing      |
|------------------|        |---------------------------|           |------------------|
| id (PK, 1-24)    |        | id (PK)                   |           | vehicle_type(PK) |
| zone (car/bike)  |        | user_id (FK -> profiles)  |           | rate_normal      |
| label (C1, B1..) |        | slot_id (FK -> slots)     |           | rate_open        |
| active (boolean) |        | plate                     |           | penalty (1.5x)   |
+------------------+        | vehicle_type              |           +------------------+
                            | start_time, end_time      |
                            | entered_at, exited_at     |
                            | status ('booked'/'active'/|
                            |         'completed'/...)  |
                            | fee, paid, created_at     |
                            +-------------+-------------+
                                          | 1:N
                                          v
                            +---------------------------+
                            |    booking_extensions     |
                            |---------------------------|
                            | id (PK)                   |
                            | booking_id (FK)           |
                            | old_end, new_end, at      |
                            +---------------------------+
```

### Table Definitions

1. **`profiles`**
   - **Purpose:** Stores application user data linked directly to Supabase authentication identity.
   - **Key Columns:** `id (UUID PK)`, `name (TEXT)`, `name_confirmed (BOOLEAN)`, `role (TEXT: 'driver' | 'admin')`.
   - **Integrity:** `REFERENCES auth.users ON DELETE CASCADE`.

2. **`vehicles`**
   - **Purpose:** Fast-lookup vehicle registry for each driver.
   - **Key Columns:** `id (BIGSERIAL PK)`, `user_id (UUID FK)`, `plate (TEXT)`, `type (TEXT: 'car' | 'bike')`.
   - **Constraints:** `UNIQUE(user_id, plate)` prevents duplicate vehicle entries for the same account.

3. **`slots`**
   - **Purpose:** Represents the 24 physical parking bays (12 for cars Skewed at 18°, 12 for bikes).
   - **Key Columns:** `id (INT PK)`, `zone (TEXT: 'car' | 'bike')`, `label (TEXT: 'C1'-'C12', 'B1'-'B12')`, `active (BOOLEAN)`.

4. **`pricing`**
   - **Purpose:** Base rates and multipliers for dynamic parking calculation.
   - **Key Columns:** `vehicle_type (TEXT PK)`, `rate_normal (NUMERIC)`, `rate_open (NUMERIC)`, `penalty (NUMERIC DEFAULT 1.5)`.

5. **`bookings`**
   - **Purpose:** Core transactional table recording reservations, occupancy, timestamps, and fees.
   - **Key Columns:** `id (BIGSERIAL PK)`, `user_id (UUID FK)`, `slot_id (INT FK)`, `plate (TEXT)`, `vehicle_type (TEXT)`, `start_time (TIMESTAMPTZ)`, `end_time (TIMESTAMPTZ)`, `status (TEXT)`, `entered_at (TIMESTAMPTZ)`, `exited_at (TIMESTAMPTZ)`, `fee (NUMERIC)`, `paid (BOOLEAN)`.

6. **`booking_extensions`**
   - **Purpose:** Immutable audit ledger tracking every time a driver extends an exit deadline.
   - **Key Columns:** `id (BIGSERIAL PK)`, `booking_id (BIGINT FK)`, `old_end (TIMESTAMPTZ)`, `new_end (TIMESTAMPTZ)`, `at (TIMESTAMPTZ)`.

---

## 4. Deep-Dive: How Backend Logic Works

### A. Automatic Profile Provisioning (Trigger & Function)
When a user signs up via Google OAuth or Email/Password, Supabase writes to `auth.users`. A PostgreSQL trigger automatically fires:

```sql
CREATE FUNCTION handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN 
  INSERT INTO profiles(id, name)
  VALUES (
    new.id, 
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1))
  ); 
  RETURN new; 
END$$;

CREATE TRIGGER on_signup 
AFTER INSERT ON auth.users 
FOR EACH ROW EXECUTE FUNCTION handle_new_user();
```
*Outcome:* The application never experiences a "missing user profile" anomaly; relational integrity between auth and public profiles is guaranteed.

---

### B. Dynamic Slot Status (Computed Views)
Instead of running periodic background cron jobs to update slot colors, the database derives live occupancy mathematically from the current server clock (`now()`):

```sql
CREATE VIEW slot_status AS 
SELECT s.id, s.zone, s.label, s.active,
  CASE 
    WHEN EXISTS(
      SELECT 1 FROM bookings b 
      WHERE b.slot_id = s.id 
        AND (b.status = 'active' 
             OR (b.status = 'booked' 
                 AND now() >= b.start_time 
                 AND now() < coalesce(b.end_time, 'infinity')))
    ) THEN 'red' 
    ELSE 'green' 
  END AS color 
FROM slots s;
```
*How it works in the backend:*
- When a driver cancels, their booking becomes `cancelled`, so the slot turns **green** instantly.
- When a driver exits, status turns `completed`, turning the slot **green** immediately.
- If a booking's `end_time` passes, the condition `now() < b.end_time` turns false, returning the bay to **green** automatically without any update queries needed.

---

### C. Concurrency Control & Double-Booking Prevention (`book_slot`)
In high-traffic parking lots, two drivers could attempt to reserve the same bay simultaneously. The `book_slot` function uses **Pessimistic Row-Level Locking (`FOR UPDATE`)**:

```sql
CREATE FUNCTION book_slot(p_slot int, p_plate text, p_start timestamptz, p_end timestamptz) 
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE s slots; bid bigint;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Sign in first'; END IF;
  
  -- Lock slot row against race conditions:
  SELECT * INTO s FROM slots WHERE slots.id = p_slot AND active FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Slot unavailable'; END IF;
  
  IF p_end IS NOT NULL AND p_end <= p_start THEN 
    RAISE EXCEPTION 'Exit must be after entry'; 
  END IF;
  
  -- Overlap detection algorithm:
  IF EXISTS(
    SELECT 1 FROM bookings b 
    WHERE b.slot_id = p_slot 
      AND b.status IN ('booked', 'active') 
      AND p_start < coalesce(b.end_time, 'infinity') 
      AND coalesce(p_end, 'infinity') > b.start_time
  ) THEN 
    RAISE EXCEPTION 'Slot already booked for this time'; 
  END IF;
  
  INSERT INTO bookings(user_id, slot_id, plate, vehicle_type, start_time, end_time) 
  VALUES (auth.uid(), p_slot, UPPER(p_plate), s.zone, p_start, p_end) 
  RETURNING bookings.id INTO bid;
  
  RETURN bid;
END$$;
```

---

### D. Billing Computation on Exit (`exit_booking`)
When the vehicle leaves the parking lot, `exit_booking` computes exact fees according to business rules:

```sql
CREATE FUNCTION exit_booking(p_id bigint) RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE b bookings; pr pricing; used int; planned int; f numeric;
BEGIN
  SELECT * INTO b FROM bookings WHERE id = p_id AND user_id = auth.uid() AND status = 'active' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Not parked'; END IF;
  
  SELECT * INTO pr FROM pricing WHERE vehicle_type = b.vehicle_type;
  
  -- Minutes parked:
  used := ceil(extract(epoch FROM now() - b.entered_at) / 60);
  
  IF b.end_time IS NULL THEN 
    -- Open-ended booking: charged at rate_open per hour
    f := greatest(ceil(used / 60.0), 1) * pr.rate_open;
  ELSE 
    -- Pre-scheduled booking:
    planned := ceil(extract(epoch FROM b.end_time - b.start_time) / 60);
    -- Normal rate for scheduled time + 1.5x penalty rate for overdue time:
    f := greatest(ceil(least(used, planned) / 60.0), 1) * pr.rate_normal 
       + ceil(greatest(used - planned, 0) / 60.0) * pr.rate_normal * pr.penalty;
  END IF;
  
  UPDATE bookings SET status = 'completed', exited_at = now(), fee = f WHERE id = p_id;
  RETURN f;
END$$;
```

---

### E. Late-Cancellation Fee Policy (`cancel_booking`)
- Cancellation **> 1 hour prior to entry:** Completely free (Fee = ₹0).
- Cancellation **< 1 hour prior to entry:** Charges 1 hour at normal rate to prevent empty-slot holding.

```sql
IF b.start_time - now() < interval '1 hour' THEN 
  SELECT rate_normal INTO f FROM pricing WHERE vehicle_type = b.vehicle_type; 
END IF;
UPDATE bookings SET status = 'cancelled', fee = f WHERE id = p_id;
```

---

## 5. Security Architecture: Row Level Security (RLS)

PostgreSQL Row Level Security ensures that API requests cannot tamper with data belonging to other drivers:

| Table | Policy Name | Permitted Operations | Rule Definition |
|-------|-------------|----------------------|-----------------|
| `profiles` | `p_sel` | SELECT | `id = auth.uid() OR is_admin()` |
| `profiles` | `p_upd` | UPDATE | `id = auth.uid()` (Restricted to `name`, `name_confirmed` only) |
| `vehicles` | `v_all` | ALL (CRUD) | `user_id = auth.uid()` |
| `slots` | `s_sel` / `s_upd` | SELECT / UPDATE | Select: Public (`true`); Update: `is_admin()` only |
| `pricing` | `r_sel` / `r_upd` | SELECT / UPDATE | Select: Public (`true`); Update: `is_admin()` only |
| `bookings` | `b_sel` | SELECT | `user_id = auth.uid() OR is_admin()` |
| `bookings` | `b_upd` | UPDATE | `is_admin()` (Driver cannot mark their own bills as paid) |

---

## 6. Verification and Deployment Status
- **Backend Database:** Connected and operational on Supabase instance `svryjfkbrmchgjvayfgr.supabase.co`.
- **Frontend Client:** Deployed to GitHub Pages at [https://jeevan-reddy-codee.github.io/Smart-Parking-System/](https://jeevan-reddy-codee.github.io/Smart-Parking-System/).
- **Authentication:** Integrated with Google OAuth and Email/Password flows with automatic URL state cleanup.
