-- This script runs automatically the first time the container starts.
-- It creates a small demo table and inserts a few rows.

CREATE TABLE IF NOT EXISTS public.sample_items (
    id   SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    qty  INTEGER DEFAULT 0
);

INSERT INTO public.sample_items (name, qty) VALUES
('Apple', 10),
('Banana', 20),
('Cherry', 15);
