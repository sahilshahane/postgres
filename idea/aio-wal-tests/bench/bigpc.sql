INSERT INTO big_:client_id SELECT g, repeat(md5(g::text), 8) FROM generate_series(1,500) g;
