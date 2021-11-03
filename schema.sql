create extension if not exists "moddatetime" with schema "extensions" version '1.0';

create type "public"."language" as enum ('typescript');

create table "public"."profiles" (
    "id" uuid not null,
    "created_at" timestamp with time zone not null,
    "updated_at" timestamp with time zone,
    "username" text not null,
    "avatar_url" text not null,
    "full_name" text not null default '"default"'::text
);


alter table "public"."profiles" enable row level security;

create table "public"."quizzes" (
    "id" bigint generated by default as identity not null,
    "created_at" timestamp with time zone not null default now(),
    "updated_at" timestamp with time zone not null default now(),
    "description" character varying,
    "start_code" character varying not null,
    "target_output" character varying not null,
    "language" language not null,
    "created_by" uuid,
    "friendly_id" character varying
);


alter table "public"."quizzes" enable row level security;

CREATE UNIQUE INDEX profiles_pkey ON public.profiles USING btree (id);

CREATE UNIQUE INDEX profiles_username_key ON public.profiles USING btree (username);

CREATE UNIQUE INDEX quizzes_pkey ON public.quizzes USING btree (id);


alter table "public"."profiles" add constraint "profiles_pkey" PRIMARY KEY using index "profiles_pkey";

alter table "public"."quizzes" add constraint "quizzes_pkey" PRIMARY KEY using index "quizzes_pkey";


alter table "public"."profiles" add constraint "profiles_id_fkey" FOREIGN KEY (id) REFERENCES auth.users(id);

alter table "public"."profiles" add constraint "profiles_username_key" UNIQUE using index "profiles_username_key";

alter table "public"."quizzes" add constraint "quizzes_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.create_profile_for_new_user()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
  BEGIN
    INSERT INTO public.profiles (id, created_at, updated_at, username, avatar_url, full_name)
    VALUES (
      NEW.id,
      NEW.created_at,
      NEW.updated_at,
      NEW.raw_user_meta_data ->> 'user_name',
      NEW.raw_user_meta_data ->> 'avatar_url',
      NEW.raw_user_meta_data ->> 'full_name'
    );
    RETURN NEW;
  END;
  $function$
;

CREATE OR REPLACE FUNCTION extensions.grant_pg_net_access()
 RETURNS event_trigger
 LANGUAGE plpgsql
AS $function$
    BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_event_trigger_ddl_commands() AS ev
        JOIN pg_extension AS ext
        ON ev.objid = ext.oid
        WHERE ext.extname = 'pg_net'
    )
    THEN
        IF NOT EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'supabase_functions_admin'
        )
        THEN
        CREATE USER supabase_functions_admin NOINHERIT CREATEROLE LOGIN NOREPLICATION;
        END IF;

        GRANT USAGE ON SCHEMA net TO supabase_functions_admin, postgres, anon, authenticated, service_role;

        ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
        ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SECURITY DEFINER;
        ALTER function net.http_collect_response(request_id bigint, async boolean) SECURITY DEFINER;

        ALTER function net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
        ALTER function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) SET search_path = net;
        ALTER function net.http_collect_response(request_id bigint, async boolean) SET search_path = net;

        REVOKE ALL ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;
        REVOKE ALL ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) FROM PUBLIC;
        REVOKE ALL ON FUNCTION net.http_collect_response(request_id bigint, async boolean) FROM PUBLIC;

        GRANT EXECUTE ON FUNCTION net.http_get(url text, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
        GRANT EXECUTE ON FUNCTION net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
        GRANT EXECUTE ON FUNCTION net.http_collect_response(request_id bigint, async boolean) TO supabase_functions_admin, postgres, anon, authenticated, service_role;
    END IF;
    END;
    $function$
;

CREATE OR REPLACE FUNCTION storage.extension(name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
_parts text[];
_filename text;
BEGIN
	select string_to_array(name, '/') into _parts;
	select _parts[array_length(_parts,1)] into _filename;
	-- @todo return the last part instead of 2
	return split_part(_filename, '.', 2);
END
$function$
;

CREATE OR REPLACE FUNCTION storage.filename(name text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[array_length(_parts,1)];
END
$function$
;

CREATE OR REPLACE FUNCTION storage.foldername(name text)
 RETURNS text[]
 LANGUAGE plpgsql
AS $function$
DECLARE
_parts text[];
BEGIN
	select string_to_array(name, '/') into _parts;
	return _parts[1:array_length(_parts,1)-1];
END
$function$
;

CREATE OR REPLACE FUNCTION storage.get_size_by_bucket()
 RETURNS TABLE(size bigint, bucket_id text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    return query
        select sum((metadata->>'size')::int) as size, obj.bucket_id
        from "storage".objects as obj
        group by obj.bucket_id;
END
$function$
;

CREATE OR REPLACE FUNCTION storage.search(prefix text, bucketname text, limits integer DEFAULT 100, levels integer DEFAULT 1, offsets integer DEFAULT 0)
 RETURNS TABLE(name text, id uuid, updated_at timestamp with time zone, created_at timestamp with time zone, last_accessed_at timestamp with time zone, metadata jsonb)
 LANGUAGE plpgsql
AS $function$
BEGIN
	return query 
		with files_folders as (
			select path_tokens[levels] as folder
			from storage.objects
			where objects.name ilike prefix || '%'
			and bucket_id = bucketname
			GROUP by folder
			limit limits
			offset offsets
		) 
		select files_folders.folder as name, objects.id, objects.updated_at, objects.created_at, objects.last_accessed_at, objects.metadata from files_folders 
		left join storage.objects
		on prefix || files_folders.folder = objects.name
        where objects.id is null or objects.bucket_id=bucketname;
END
$function$
;

create policy "Public profiles are viewable by everyone."
on "public"."profiles"
as permissive
for select
to public
using (true);


create policy "Users can insert their own profile."
on "public"."profiles"
as permissive
for insert
to public
with check (auth.uid() = id);


create policy "Users can update own profile."
on "public"."profiles"
as permissive
for update
to public
using ((auth.uid() = id));


create policy "Quizzes are viewable by everyone"
on "public"."quizzes"
as permissive
for select
to public
using (true);


create policy "Users can insert quizzes created by themself"
on "public"."quizzes"
as permissive
for insert
to public
with check (auth.uid() = created_by);


create policy "Users can update their own quizzes"
on "public"."quizzes"
as permissive
for update
to public
using ((auth.uid() = created_by))
with check (auth.uid() = created_by);


create policy "Anyone can update an avatar."
on "storage"."objects"
as permissive
for update
to public
with check (bucket_id = 'avatars'::text);


create policy "Anyone can upload an avatar."
on "storage"."objects"
as permissive
for insert
to public
with check (bucket_id = 'avatars'::text);


create policy "Avatar images are publicly accessible."
on "storage"."objects"
as permissive
for select
to public
using ((bucket_id = 'avatars'::text));


CREATE TRIGGER create_profile_on_signup AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION create_profile_for_new_user();

CREATE TRIGGER handle_updated_at BEFORE UPDATE ON public.quizzes FOR EACH ROW EXECUTE FUNCTION moddatetime('updated_at');


