-- ABC Mall Parking: run this whole file in Supabase > SQL Editor.
-- After running: make yourself admin with
--   update profiles set role='admin' where id=(select id from auth.users where email='YOU@gmail.com');

create table profiles(id uuid primary key references auth.users on delete cascade, name text, name_confirmed boolean default false, role text default 'driver' check(role in('driver','admin')));
create table vehicles(id bigserial primary key, user_id uuid not null references profiles on delete cascade, plate text not null, type text not null check(type in('car','bike')), unique(user_id,plate));
create table slots(id int primary key, zone text not null check(zone in('car','bike')), label text not null, active boolean default true);
create table pricing(vehicle_type text primary key, rate_normal numeric not null, rate_open numeric not null, penalty numeric default 1.5);
create table bookings(id bigserial primary key, user_id uuid not null references profiles, slot_id int not null references slots, plate text not null, vehicle_type text not null,
  start_time timestamptz not null, end_time timestamptz, status text default 'booked' check(status in('booked','active','completed','cancelled')),
  entered_at timestamptz, exited_at timestamptz, fee numeric default 0, paid boolean default false, created_at timestamptz default now());
create table booking_extensions(id bigserial primary key, booking_id bigint references bookings, old_end timestamptz, new_end timestamptz, at timestamptz default now());

insert into slots select g,'car','C'||g from generate_series(1,12) g;
insert into slots select 12+g,'bike','B'||g from generate_series(1,12) g;
insert into pricing values('car',30,40,1.5),('bike',20,30,1.5);

-- Slot colour is computed from the current time (cancel/exit/expiry turn it green again)
create view slot_status as select s.id,s.zone,s.label,s.active,
  case when exists(select 1 from bookings b where b.slot_id=s.id and (b.status='active' or (b.status='booked' and now()>=b.start_time and now()<coalesce(b.end_time,'infinity')))) then 'red' else 'green' end as color from slots s;
create view slot_timeline as select slot_id,start_time,end_time,status from bookings where status in('booked','active');
grant select on slot_status,slot_timeline to anon,authenticated;

-- Profile on signup: Google name becomes the username (user confirms it in the site)
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,name) values(new.id,coalesce(new.raw_user_meta_data->>'full_name',new.raw_user_meta_data->>'name',split_part(new.email,'@',1))); return new; end$$;
create trigger on_signup after insert on auth.users for each row execute function handle_new_user();

create function is_admin() returns boolean language sql security definer stable set search_path=public as $$select exists(select 1 from profiles where id=auth.uid() and role='admin')$$;

alter table profiles enable row level security; alter table vehicles enable row level security; alter table slots enable row level security;
alter table pricing enable row level security; alter table bookings enable row level security; alter table booking_extensions enable row level security;
create policy p_sel on profiles for select using(id=auth.uid() or is_admin());
create policy p_upd on profiles for update using(id=auth.uid());
revoke update on profiles from authenticated; grant update(name,name_confirmed) on profiles to authenticated;
create policy v_all on vehicles for all using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy s_sel on slots for select using(true);   create policy s_upd on slots for update using(is_admin());
create policy r_sel on pricing for select using(true); create policy r_upd on pricing for update using(is_admin());
create policy b_sel on bookings for select using(user_id=auth.uid() or is_admin());
create policy b_upd on bookings for update using(is_admin());   -- admin marks bills paid at the toll

create function book_slot(p_slot int,p_plate text,p_start timestamptz,p_end timestamptz) returns bigint language plpgsql security definer set search_path=public as $$
declare s slots; bid bigint;
begin
 if auth.uid() is null then raise exception 'Sign in first'; end if;
 select * into s from slots where slots.id=p_slot and active for update;
 if not found then raise exception 'Slot unavailable'; end if;
 if p_end is not null and p_end<=p_start then raise exception 'Exit must be after entry'; end if;
 if exists(select 1 from bookings b where b.slot_id=p_slot and b.status in('booked','active') and p_start<coalesce(b.end_time,'infinity') and coalesce(p_end,'infinity')>b.start_time)
  then raise exception 'Slot already booked for this time'; end if;
 insert into bookings(user_id,slot_id,plate,vehicle_type,start_time,end_time) values(auth.uid(),p_slot,upper(p_plate),s.zone,p_start,p_end) returning bookings.id into bid;
 return bid;
end$$;

create function cancel_booking(p_id bigint) returns numeric language plpgsql security definer set search_path=public as $$
declare b bookings; f numeric:=0;
begin
 select * into b from bookings where id=p_id and user_id=auth.uid() and status='booked' for update;
 if not found then raise exception 'Cannot cancel'; end if;
 if b.start_time-now()<interval '1 hour' then select rate_normal into f from pricing where vehicle_type=b.vehicle_type; end if;
 update bookings set status='cancelled',fee=f where id=p_id; return f;
end$$;

create function enter_booking(p_id bigint) returns void language plpgsql security definer set search_path=public as $$
begin
 update bookings set status='active',entered_at=now() where id=p_id and user_id=auth.uid() and status='booked' and now()>=start_time;
 if not found then raise exception 'Entry time has not started'; end if;
end$$;

create function extend_booking(p_id bigint,p_end timestamptz) returns void language plpgsql security definer set search_path=public as $$
declare b bookings;
begin
 select * into b from bookings where id=p_id and user_id=auth.uid() and status in('booked','active') and end_time is not null for update;
 if not found then raise exception 'Cannot extend'; end if;
 if p_end<=b.end_time then raise exception 'New exit must be later'; end if;
 if exists(select 1 from bookings o where o.slot_id=b.slot_id and o.id<>b.id and o.status in('booked','active') and b.end_time<coalesce(o.end_time,'infinity') and p_end>o.start_time)
  then raise exception 'The next booking on this slot blocks that extension'; end if;
 insert into booking_extensions(booking_id,old_end,new_end) values(b.id,b.end_time,p_end);
 update bookings set end_time=p_end where id=b.id;
end$$;

create function exit_booking(p_id bigint) returns numeric language plpgsql security definer set search_path=public as $$
declare b bookings; pr pricing; used int; planned int; f numeric;
begin
 select * into b from bookings where id=p_id and user_id=auth.uid() and status='active' for update;
 if not found then raise exception 'Not parked'; end if;
 select * into pr from pricing where vehicle_type=b.vehicle_type;
 used:=ceil(extract(epoch from now()-b.entered_at)/60);
 if b.end_time is null then f:=greatest(ceil(used/60.0),1)*pr.rate_open;
 else planned:=ceil(extract(epoch from b.end_time-b.start_time)/60);
  f:=greatest(ceil(least(used,planned)/60.0),1)*pr.rate_normal+ceil(greatest(used-planned,0)/60.0)*pr.rate_normal*pr.penalty;
 end if;
 update bookings set status='completed',exited_at=now(),fee=f where id=p_id; return f;
end$$;
