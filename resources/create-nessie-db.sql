create database nessie;
create user nessie with password 'nessie123';
grant connect on database nessie to nessie;
\c nessie
create schema nessie authorization nessie;
grant all privileges on schema nessie to nessie;