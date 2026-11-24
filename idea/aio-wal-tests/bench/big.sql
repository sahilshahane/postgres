INSERT INTO big SELECT g, repeat(md5(g::text), 8) FROM generate_series(1,500) g;
