-- 흑과 백: 방송 규칙 기반 온라인 대전용 SQL
-- 기존 프로젝트에 적용 가능하도록 기존 테이블에 필요한 컬럼을 추가하고 RPC 함수를 교체합니다.
-- Supabase SQL Editor에서 전체 실행하세요.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.bw_rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  status text not null default 'waiting' check (status in ('waiting','playing','finished')),
  round_no integer not null default 1 check (round_no between 1 and 10),
  phase text not null default 'main' check (phase in ('main','tiebreak')),
  host_name text not null,
  guest_name text,
  host_avatar text not null default '🕴️',
  guest_avatar text not null default '🕵️',
  host_token text not null,
  guest_token text,
  host_score integer not null default 0,
  guest_score integer not null default 0,
  host_points integer not null default 99,
  guest_points integer not null default 99,
  challenged_role text not null default 'host' check (challenged_role in ('host','guest')),
  game_mode text not null default 'bw2' check (game_mode in ('bw1','bw2','bw_set')),
  starter_role text check (starter_role in ('host','guest')),
  host_used integer[] not null default '{}',
  guest_used integer[] not null default '{}',
  host_pending integer,
  guest_pending integer,
  history jsonb not null default '[]'::jsonb,
  last_result jsonb,
  winner text,
  host_reaction jsonb,
  guest_reaction jsonb,
  bet_phase text not null default 'setup',
  host_bet_ready boolean not null default false,
  guest_bet_ready boolean not null default false,
  host_bet_order integer[] not null default '{}',
  guest_bet_order integer[] not null default '{}',
  host_bet_wagers integer[] not null default '{}',
  guest_bet_wagers integer[] not null default '{}',
  host_bet_chips integer not null default 30,
  guest_bet_chips integer not null default 30,
  bet_revealed boolean[] not null default array_fill(false,array[10]),
  bet_folded boolean[] not null default array_fill(false,array[10]),
  bet_history jsonb not null default '[]'::jsonb,
  set_board integer[] not null default '{}',
  set_found_sets jsonb not null default '[]'::jsonb,
  set_events jsonb not null default '[]'::jsonb,
  set_turn_role text check (set_turn_role in ('host','guest')),
  set_turn_deadline timestamptz,
  set_claim_role text check (set_claim_role in ('host','guest')),
  set_claim_deadline timestamptz,
  set_pass_streak integer not null default 0,
  created_at timestamptz not null default now()
);

-- 기존에 만든 테이블을 유지하면서 신규 규칙용 필드를 추가합니다.
alter table public.bw_rooms add column if not exists phase text not null default 'main';
alter table public.bw_rooms add column if not exists host_avatar text not null default '🕴️';
alter table public.bw_rooms add column if not exists guest_avatar text not null default '🕵️';
alter table public.bw_rooms add column if not exists host_points integer not null default 99;
alter table public.bw_rooms add column if not exists guest_points integer not null default 99;
alter table public.bw_rooms add column if not exists challenged_role text not null default 'host';
alter table public.bw_rooms add column if not exists game_mode text not null default 'bw2';
alter table public.bw_rooms add column if not exists starter_role text;
alter table public.bw_rooms add column if not exists host_reaction jsonb;
alter table public.bw_rooms add column if not exists guest_reaction jsonb;
alter table public.bw_rooms add column if not exists bet_phase text not null default 'setup';
alter table public.bw_rooms add column if not exists host_bet_ready boolean not null default false;
alter table public.bw_rooms add column if not exists guest_bet_ready boolean not null default false;
alter table public.bw_rooms add column if not exists host_bet_order integer[] not null default '{}';
alter table public.bw_rooms add column if not exists guest_bet_order integer[] not null default '{}';
alter table public.bw_rooms add column if not exists host_bet_wagers integer[] not null default '{}';
alter table public.bw_rooms add column if not exists guest_bet_wagers integer[] not null default '{}';
alter table public.bw_rooms add column if not exists host_bet_chips integer not null default 30;
alter table public.bw_rooms add column if not exists guest_bet_chips integer not null default 30;
alter table public.bw_rooms add column if not exists bet_revealed boolean[] not null default array_fill(false,array[10]);
alter table public.bw_rooms add column if not exists bet_folded boolean[] not null default array_fill(false,array[10]);
alter table public.bw_rooms add column if not exists bet_history jsonb not null default '[]'::jsonb;
alter table public.bw_rooms add column if not exists set_board integer[] not null default '{}';
alter table public.bw_rooms add column if not exists set_found_sets jsonb not null default '[]'::jsonb;
alter table public.bw_rooms add column if not exists set_events jsonb not null default '[]'::jsonb;
alter table public.bw_rooms add column if not exists set_turn_role text;
alter table public.bw_rooms add column if not exists set_turn_deadline timestamptz;
alter table public.bw_rooms add column if not exists set_claim_role text;
alter table public.bw_rooms add column if not exists set_claim_deadline timestamptz;
alter table public.bw_rooms add column if not exists set_pass_streak integer not null default 0;
alter table public.bw_rooms drop constraint if exists bw_rooms_game_mode_check;
alter table public.bw_rooms add constraint bw_rooms_game_mode_check check (game_mode in ('bw1','bw2','bw_bet','bw_set'));
create index if not exists bw_rooms_code_idx on public.bw_rooms(code);
alter table public.bw_rooms enable row level security;
revoke all on public.bw_rooms from anon, authenticated;

-- 구버전 create_room(text)와의 충돌을 방지합니다.
drop function if exists public.bw_create_room(text);
drop function if exists public.bw_create_room(text,text);
drop function if exists public.bw_create_room(text,text,text);
drop function if exists public.bw_create_room(text,text,text,text);
drop function if exists public.bw_join_room(text,text);
drop function if exists public.bw_join_room(text,text,text);

create or replace function public.bw_create_room(p_name text, p_challenged_role text, p_avatar text, p_game_mode text default 'bw2')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare v_code text; v_token text; v_name text; v_challenged text; v_mode text;
begin
  v_name := left(coalesce(nullif(trim(p_name),''),'플레이어 1'),16);
  v_challenged := case when p_game_mode='bw_set' then 'host' when p_challenged_role in ('host','guest') then p_challenged_role else 'host' end;
  v_mode := case when p_game_mode in ('bw1','bw_bet','bw_set') then p_game_mode else 'bw2' end;
  loop
    v_code := upper(substr(encode(extensions.gen_random_bytes(6),'hex'),1,6));
    exit when not exists(select 1 from public.bw_rooms where code=v_code);
  end loop;
  v_token := encode(extensions.gen_random_bytes(24),'hex');
  insert into public.bw_rooms(code,host_name,host_token,host_avatar,challenged_role,game_mode,host_points,guest_points,phase,round_no,starter_role)
  values(v_code,v_name,v_token,coalesce(nullif(p_avatar,''),'🕴️'),v_challenged,v_mode,case when v_mode in ('bw1','bw_bet') then 0 else 99 end,case when v_mode in ('bw1','bw_bet') then 0 else 99 end,'main',1,null);
  return jsonb_build_object('code',v_code,'token',v_token);
end $$;

create or replace function public.bw_join_room(p_code text,p_name text,p_avatar text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare r public.bw_rooms%rowtype; v_token text; v_name text;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다. 초대 코드를 확인하세요.'; end if;
  if r.status <> 'waiting' or r.guest_token is not null then raise exception '이미 시작했거나 두 명이 참가한 방입니다.'; end if;
  v_token := encode(extensions.gen_random_bytes(24),'hex');
  v_name := left(coalesce(nullif(trim(p_name),''),'플레이어 2'),16);
  update public.bw_rooms set guest_name=v_name,guest_token=v_token,guest_avatar=coalesce(nullif(p_avatar,''),'🕵️'),status='playing' where id=r.id;
  return jsonb_build_object('code',r.code,'token',v_token);
end $$;

create or replace function public.bw_choose_starter(p_code text,p_token text,p_starter text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare r public.bw_rooms%rowtype; v_role text; v_starter text; v_board integer[];
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host';
  elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest';
  else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.status <> 'playing' then raise exception '상대가 입장한 뒤 선공을 정할 수 있습니다.'; end if;
  if r.game_mode='bw_bet' then raise exception '베팅! 흑과 백은 선공 선택이 필요하지 않습니다.'; end if;
  if r.starter_role is not null then raise exception '선공이 이미 결정되었습니다.'; end if;
  if v_role <> r.challenged_role then raise exception '상대로 지목된 플레이어만 선공을 결정할 수 있습니다.'; end if;
  if p_starter in ('host','guest') then v_starter:=p_starter;
  elsif p_starter='coin' then v_starter:=case when random()<0.5 then 'host' else 'guest' end;
  else raise exception '선공 선택 값이 올바르지 않습니다.'; end if;
  if r.game_mode='bw_set' then
    select array_agg(card_id order by random()) into v_board
    from (select generate_series(0,26) as card_id order by random() limit 9) cards;
    update public.bw_rooms set starter_role=v_starter,set_turn_role=v_starter,
      set_turn_deadline=now()+interval '10 seconds',set_board=v_board,
      set_found_sets='[]'::jsonb,set_events='[]'::jsonb,set_pass_streak=0
    where id=r.id;
  else
    update public.bw_rooms set starter_role=v_starter where id=r.id;
  end if;
  return jsonb_build_object('ok',true,'starter_role',v_starter);
end $$;

create or replace function public.bw_set_is_valid(p_a integer,p_b integer,p_c integer)
returns boolean language sql immutable parallel safe as $$
  select (
    (p_a%3=p_b%3 and p_b%3=p_c%3) or
    (p_a%3<>p_b%3 and p_a%3<>p_c%3 and p_b%3<>p_c%3)
  ) and (
    ((p_a/3)%3=(p_b/3)%3 and (p_b/3)%3=(p_c/3)%3) or
    ((p_a/3)%3<>(p_b/3)%3 and (p_a/3)%3<>(p_c/3)%3 and (p_b/3)%3<>(p_c/3)%3)
  ) and (
    ((p_a/9)=(p_b/9) and (p_b/9)=(p_c/9)) or
    ((p_a/9)<>(p_b/9) and (p_a/9)<>(p_c/9) and (p_b/9)<>(p_c/9))
  )
$$;

create or replace function public.bw_set_board_has_unfound(p_board integer[],p_found jsonb)
returns boolean language plpgsql immutable parallel safe as $$
declare i integer; j integer; k integer; a integer; b integer; c integer;
begin
  for i in 1..coalesce(array_length(p_board,1),0) loop
    for j in i+1..coalesce(array_length(p_board,1),0) loop
      for k in j+1..coalesce(array_length(p_board,1),0) loop
        a:=p_board[i]; b:=p_board[j]; c:=p_board[k];
        if public.bw_set_is_valid(a,b,c) then
          if not coalesce(p_found,'[]'::jsonb) @> jsonb_build_array(jsonb_build_array(least(a,b,c),a+b+c-least(a,b,c)-greatest(a,b,c),greatest(a,b,c))) then
            return true;
          end if;
        end if;
      end loop;
    end loop;
  end loop;
  return false;
end $$;

create or replace function public.bw_set_finish_round(p_code text,p_reason text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  r public.bw_rooms%rowtype;
  v_next_starter text;
  v_board integer[];
  v_winner text;
  v_next_round integer;
  v_next_phase text;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found or r.game_mode<>'bw_set' or r.status<>'playing' then raise exception '결! 합! 라운드를 종료할 수 있는 상태가 아닙니다.'; end if;
  v_next_starter:=case when r.starter_role='host' then 'guest' else 'host' end;
  if r.round_no>=10 then
    if r.host_score<>r.guest_score then
      v_winner:=case when r.host_score>r.guest_score then 'host' else 'guest' end;
      update public.bw_rooms set
        history=history||jsonb_build_array(jsonb_build_object('phase',r.phase,'round',r.round_no,'board',r.set_board,'events',r.set_events,'host_score',r.host_score,'guest_score',r.guest_score,'reason',p_reason)),
        status='finished',winner=v_winner,set_turn_role=null,set_turn_deadline=null,set_claim_role=null,set_claim_deadline=null
      where id=r.id;
      return jsonb_build_object('ok',true,'round_finished',true,'game_finished',true,'winner',v_winner);
    end if;
    v_next_phase:='tiebreak'; v_next_round:=1;
  else
    v_next_phase:=r.phase; v_next_round:=r.round_no+1;
  end if;
  select array_agg(card_id order by random()) into v_board
  from (select generate_series(0,26) as card_id order by random() limit 9) cards;
  update public.bw_rooms set
    history=history||jsonb_build_array(jsonb_build_object('phase',r.phase,'round',r.round_no,'board',r.set_board,'events',r.set_events,'host_score',r.host_score,'guest_score',r.guest_score,'reason',p_reason)),
    phase=v_next_phase,round_no=v_next_round,starter_role=v_next_starter,
    set_board=v_board,set_found_sets='[]'::jsonb,set_events='[]'::jsonb,set_turn_role=v_next_starter,
    set_turn_deadline=now()+interval '10 seconds',set_claim_role=null,set_claim_deadline=null,set_pass_streak=0
  where id=r.id;
  return jsonb_build_object('ok',true,'round_finished',true,'game_finished',false);
end $$;

create or replace function public.bw_set_action(p_code text,p_token text,p_action text,p_cards integer[] default '{}')
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  r public.bw_rooms%rowtype;
  v_role text; v_other text; v_event jsonb; v_found jsonb; v_valid boolean;
  v_pass_streak integer; v_a integer; v_b integer; v_c integer;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host';
  elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest';
  else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.game_mode<>'bw_set' or r.status<>'playing' or r.starter_role is null then raise exception '결! 합! 게임이 진행 중이 아닙니다.'; end if;
  v_other:=case when r.set_turn_role='host' then 'guest' else 'host' end;

  if p_action='tick' then
    if r.set_turn_role is null or now()<coalesce(r.set_claim_deadline,r.set_turn_deadline) then
      return jsonb_build_object('ok',true,'expired',false);
    end if;
    if r.set_claim_role is not null then
      v_event:=jsonb_build_object('action','claim_timeout','actor',r.set_claim_role,'winner',case when r.set_claim_role='host' then 'guest' else 'host' end,'points',-1);
      update public.bw_rooms set
        host_score=host_score+case when r.set_claim_role='host' then -1 else 0 end,
        guest_score=guest_score+case when r.set_claim_role='guest' then -1 else 0 end,
        set_events=set_events||jsonb_build_array(v_event),set_pass_streak=0,
        set_claim_role=null,set_claim_deadline=null,set_turn_role=v_other,set_turn_deadline=now()+interval '10 seconds'
      where id=r.id;
    else
      v_pass_streak:=r.set_pass_streak+1;
      v_event:=jsonb_build_object('action','timeout_pass','actor',r.set_turn_role,'winner',null,'pass_streak',v_pass_streak);
      update public.bw_rooms set set_events=set_events||jsonb_build_array(v_event),set_pass_streak=v_pass_streak,
        set_turn_role=v_other,set_turn_deadline=now()+interval '10 seconds'
      where id=r.id;
      if v_pass_streak>=6 then
        return public.bw_set_finish_round(p_code,'six_passes');
      end if;
    end if;
    return jsonb_build_object('ok',true,'expired',true);
  end if;

  if v_role<>r.set_turn_role then raise exception '현재 순서인 플레이어만 행동할 수 있습니다.'; end if;
  if now()>=coalesce(r.set_claim_deadline,r.set_turn_deadline) then return jsonb_build_object('ok',true,'stale',true); end if;

  if p_action='claim' then
    if r.set_claim_role is not null then raise exception '이미 그림 번호를 부르는 중입니다.'; end if;
    update public.bw_rooms set set_claim_role=v_role,set_claim_deadline=now()+interval '5 seconds',
      set_events=set_events||jsonb_build_array(jsonb_build_object('action','claim_started','actor',v_role,'winner',null))
    where id=r.id;
    return jsonb_build_object('ok',true,'claim_started',true);
  elsif p_action='submit' then
    if r.set_claim_role is distinct from v_role then raise exception '먼저 합을 외쳐야 그림 번호를 제출할 수 있습니다.'; end if;
    if coalesce(array_length(p_cards,1),0)<>3 or (select count(distinct n) from unnest(p_cards) n)<>3
      or exists(select 1 from unnest(p_cards) n where n<1 or n>9) then
      raise exception '현재 공개된 그림 중 서로 다른 번호 3개를 선택하세요.';
    end if;
    v_a:=least(r.set_board[p_cards[1]],r.set_board[p_cards[2]],r.set_board[p_cards[3]]);
    v_c:=greatest(r.set_board[p_cards[1]],r.set_board[p_cards[2]],r.set_board[p_cards[3]]);
    v_b:=r.set_board[p_cards[1]]+r.set_board[p_cards[2]]+r.set_board[p_cards[3]]-v_a-v_c;
    v_found:=jsonb_build_array(v_a,v_b,v_c);
    v_valid:=public.bw_set_is_valid(v_a,v_b,v_c);
    if coalesce(r.set_found_sets,'[]'::jsonb) @> jsonb_build_array(v_found) then
      v_valid:=false;
    end if;
    v_event:=jsonb_build_object('action',case when v_valid then 'set_correct' else 'set_wrong' end,'actor',v_role,'winner',case when v_valid then v_role else v_other end,'numbers',to_jsonb(p_cards),'cards',v_found,'points',case when v_valid then 1 else -1 end);
    update public.bw_rooms set
      host_score=host_score+case when v_role='host' then case when v_valid then 1 else -1 end else 0 end,
      guest_score=guest_score+case when v_role='guest' then case when v_valid then 1 else -1 end else 0 end,
      set_found_sets=case when v_valid then set_found_sets||jsonb_build_array(v_found) else set_found_sets end,
      set_events=set_events||jsonb_build_array(v_event),set_pass_streak=0,
      set_claim_role=null,set_claim_deadline=null,set_turn_role=v_other,set_turn_deadline=now()+interval '10 seconds'
    where id=r.id;
    return jsonb_build_object('ok',true,'correct',v_valid);
  elsif p_action='conclude' then
    if r.set_claim_role is not null then raise exception '먼저 진행 중인 그림 번호 제출을 마쳐야 합니다.'; end if;
    v_valid:=not public.bw_set_board_has_unfound(r.set_board,r.set_found_sets);
    v_event:=jsonb_build_object('action',case when v_valid then 'conclude_correct' else 'conclude_wrong' end,'actor',v_role,'winner',case when v_valid then v_role else v_other end,'points',case when v_valid then 3 else -1 end);
    update public.bw_rooms set
      host_score=host_score+case when v_role='host' then case when v_valid then 3 else -1 end else 0 end,
      guest_score=guest_score+case when v_role='guest' then case when v_valid then 3 else -1 end else 0 end,
      set_events=set_events||jsonb_build_array(v_event),set_pass_streak=0
    where id=r.id;
    if v_valid then return public.bw_set_finish_round(p_code,'correct_conclude'); end if;
    update public.bw_rooms set set_turn_role=v_other,set_turn_deadline=now()+interval '10 seconds' where id=r.id;
    return jsonb_build_object('ok',true,'correct',false);
  elsif p_action='pass' then
    if r.set_claim_role is not null then raise exception '합을 외친 뒤에는 그림 번호를 제출해야 합니다.'; end if;
    v_pass_streak:=r.set_pass_streak+1;
    v_event:=jsonb_build_object('action','pass','actor',v_role,'winner',null,'pass_streak',v_pass_streak);
    update public.bw_rooms set set_events=set_events||jsonb_build_array(v_event),set_pass_streak=v_pass_streak,
      set_turn_role=v_other,set_turn_deadline=now()+interval '10 seconds'
    where id=r.id;
    if v_pass_streak>=6 then return public.bw_set_finish_round(p_code,'six_passes'); end if;
    return jsonb_build_object('ok',true,'passed',true);
  else
    raise exception '알 수 없는 결! 합! 동작입니다.';
  end if;
end $$;

create or replace function public.bw_get_state(p_code text,p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare r public.bw_rooms%rowtype; v_role text; v_opp_submitted boolean; v_me_submitted boolean; v_turn text;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code));
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host'; v_me_submitted:=r.host_pending is not null; v_opp_submitted:=r.guest_pending is not null;
  elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest'; v_me_submitted:=r.guest_pending is not null; v_opp_submitted:=r.host_pending is not null;
  else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.game_mode='bw_set' then v_turn:=r.set_turn_role;
  elsif r.starter_role is null then v_turn:=null;
  elsif r.host_pending is null and r.guest_pending is null then v_turn:=r.starter_role;
  elsif r.host_pending is not null and r.guest_pending is null then v_turn:='guest';
  elsif r.guest_pending is not null and r.host_pending is null then v_turn:='host';
  else v_turn:=null; end if;
  return jsonb_build_object(
    'code',r.code,'status',r.status,'round_no',r.round_no,'phase',r.phase,'game_mode',r.game_mode,
    'bet_phase',r.bet_phase,
    'my_bet_ready',case when v_role='host' then r.host_bet_ready else r.guest_bet_ready end,
    'opponent_bet_ready',case when v_role='host' then r.guest_bet_ready else r.host_bet_ready end,
    'my_bet_order',case when v_role='host' then to_jsonb(r.host_bet_order) else to_jsonb(r.guest_bet_order) end,
    'my_bet_wagers',case when v_role='host' then to_jsonb(r.host_bet_wagers) else to_jsonb(r.guest_bet_wagers) end,
    'opponent_bet_wagers',case when r.host_bet_ready and r.guest_bet_ready then case when v_role='host' then to_jsonb(r.guest_bet_wagers) else to_jsonb(r.host_bet_wagers) end else null end,
    'my_bet_chips',case when v_role='host' then r.host_bet_chips else r.guest_bet_chips end,
    'opponent_bet_chips',case when v_role='host' then r.guest_bet_chips else r.host_bet_chips end,
    'bet_revealed',to_jsonb(r.bet_revealed),'bet_folded',to_jsonb(r.bet_folded),
    'my_current_tile',case when r.game_mode='bw_bet' and r.bet_phase='battle' and r.host_bet_ready and r.guest_bet_ready then case when v_role='host' then r.host_bet_order[r.round_no] else r.guest_bet_order[r.round_no] end else null end,
    'opponent_current_tile',case when r.game_mode='bw_bet' and r.bet_revealed[r.round_no] and not r.bet_folded[r.round_no] then case when v_role='host' then r.guest_bet_order[r.round_no] else r.host_bet_order[r.round_no] end else null end,
    'opponent_current_tile_color',case when r.game_mode='bw_bet' and r.bet_phase='battle' and r.host_bet_ready and r.guest_bet_ready then case when (case when v_role='host' then r.guest_bet_order[r.round_no] else r.host_bet_order[r.round_no] end)%2=0 then 'black' else 'white' end else null end,
    'opponent_bet_tile_colors',case when r.host_bet_ready and r.guest_bet_ready then to_jsonb(array(
      select case when tiles.tile%2=0 then 'black' else 'white' end
      from unnest(case when v_role='host' then r.guest_bet_order else r.host_bet_order end) with ordinality as tiles(tile,ordinality)
      order by tiles.ordinality
    )) else null end,
    'my_current_wager',case when r.game_mode='bw_bet' and r.bet_phase='battle' and r.host_bet_ready and r.guest_bet_ready then case when v_role='host' then r.host_bet_wagers[r.round_no] else r.guest_bet_wagers[r.round_no] end else null end,
    'opponent_current_wager',case when r.game_mode='bw_bet' and r.bet_phase='battle' and r.host_bet_ready and r.guest_bet_ready then case when v_role='host' then r.guest_bet_wagers[r.round_no] else r.host_bet_wagers[r.round_no] end else null end,
    'bet_history',case when r.status='finished' then r.bet_history else coalesce((
      select jsonb_agg(
        history.entry || jsonb_build_object(
          'host_tile',case when v_role='host' or coalesce((history.entry->>'opened')::boolean,false) then history.entry->'host_tile' else 'null'::jsonb end,
          'guest_tile',case when v_role='guest' or coalesce((history.entry->>'opened')::boolean,false) then history.entry->'guest_tile' else 'null'::jsonb end,
          'host_tile_color',case when history.entry->>'host_tile' is null then null when (history.entry->>'host_tile')::integer%2=0 then 'black' else 'white' end,
          'guest_tile_color',case when history.entry->>'guest_tile' is null then null when (history.entry->>'guest_tile')::integer%2=0 then 'black' else 'white' end
        ) order by history.ordinality
      )
      from jsonb_array_elements(coalesce(r.bet_history,'[]'::jsonb)) with ordinality as history(entry,ordinality)
    ),'[]'::jsonb) end,
    'my_tiles',to_jsonb(array(select n from generate_series(0,8) n where not (case when v_role='host' then n=any(r.host_used) else n=any(r.guest_used) end) order by n)),
    'host_remaining_tiles',9-cardinality(r.host_used),'guest_remaining_tiles',9-cardinality(r.guest_used),
    'opponent_black_tiles',case when r.game_mode='bw1' then (select count(*) from generate_series(0,8) n where n%2=0 and not (case when v_role='host' then n=any(r.guest_used) else n=any(r.host_used) end)) else null end,
    'opponent_white_tiles',case when r.game_mode='bw1' then (select count(*) from generate_series(0,8) n where n%2=1 and not (case when v_role='host' then n=any(r.guest_used) else n=any(r.host_used) end)) else null end
  ) || jsonb_build_object(
    'host_name',r.host_name,'guest_name',r.guest_name,'host_avatar',r.host_avatar,'guest_avatar',r.guest_avatar,'host_score',r.host_score,'guest_score',r.guest_score,
    'host_points',r.host_points,'guest_points',r.guest_points,'challenged_role',r.challenged_role,'starter_role',r.starter_role,
    'host_reaction',case when r.host_reaction->>'until' is not null and (r.host_reaction->>'until')::timestamptz>now() then r.host_reaction else null end,
    'guest_reaction',case when r.guest_reaction->>'until' is not null and (r.guest_reaction->>'until')::timestamptz>now() then r.guest_reaction else null end,
    'turn_role',v_turn,'role',v_role,'my_submitted',v_me_submitted,'opponent_submitted',v_opp_submitted,
    'host_pending',case when r.status='finished' and r.game_mode='bw1' then null when r.status='finished' then r.host_pending else null end,
    'guest_pending',case when r.status='finished' and r.game_mode='bw1' then null when r.status='finished' then r.guest_pending else null end,
    'my_pending',case when v_role='host' then r.host_pending else r.guest_pending end,
    'host_chip_color',case
      when r.status='finished' and r.host_pending is not null then case when (r.host_pending % 2=0 and r.game_mode='bw1') or (r.host_pending < 10 and r.game_mode='bw2') then 'black' else 'white' end
      when r.host_pending is not null then case when (r.host_pending % 2=0 and r.game_mode='bw1') or (r.host_pending < 10 and r.game_mode='bw2') then 'black' else 'white' end
      else null end,
    'guest_chip_color',case
      when r.status='finished' and r.guest_pending is not null then case when (r.guest_pending % 2=0 and r.game_mode='bw1') or (r.guest_pending < 10 and r.game_mode='bw2') then 'black' else 'white' end
      when r.guest_pending is not null then case when (r.guest_pending % 2=0 and r.game_mode='bw1') or (r.guest_pending < 10 and r.game_mode='bw2') then 'black' else 'white' end
      else null end,
    'history',case when r.game_mode in ('bw_bet','bw_set') then r.history when r.status='finished' then r.history else coalesce((
      select jsonb_agg(jsonb_build_object(
        'phase',e.value->'phase','round',e.value->'round','winner',e.value->'winner',
        'host_chip_color',case when (r.game_mode='bw1' and (e.value->>'host_number')::integer % 2=0) or (r.game_mode='bw2' and (e.value->>'host_number')::integer < 10) then 'black' else 'white' end,
        'guest_chip_color',case when (r.game_mode='bw1' and (e.value->>'guest_number')::integer % 2=0) or (r.game_mode='bw2' and (e.value->>'guest_number')::integer < 10) then 'black' else 'white' end,
        'my_number',case when v_role='host' then e.value->'host_number' else e.value->'guest_number' end
      ) order by e.ordinality)
      from jsonb_array_elements(r.history) with ordinality as e(value,ordinality)
    ),'[]'::jsonb) end,
    'last_result',case when r.last_result is null then null when r.status='finished' and r.game_mode<>'bw1' then r.last_result else jsonb_build_object(
      'phase',r.last_result->'phase','round',r.last_result->'round','winner',r.last_result->'winner',
      'host_chip_color',case when (r.last_result->>'host_number')::integer % 2=0 and r.game_mode='bw1' then 'black' when r.game_mode='bw1' then 'white' when (r.last_result->>'host_number')::integer < 10 then 'black' else 'white' end,
      'guest_chip_color',case when (r.last_result->>'guest_number')::integer % 2=0 and r.game_mode='bw1' then 'black' when r.game_mode='bw1' then 'white' when (r.last_result->>'guest_number')::integer < 10 then 'black' else 'white' end
    ) end,'winner',r.winner
  ) || jsonb_build_object(
    'set_board',to_jsonb(r.set_board),'set_found_sets',r.set_found_sets,'set_events',r.set_events,
    'set_turn_role',r.set_turn_role,'set_turn_deadline',case when r.set_turn_deadline is null then null else extract(epoch from r.set_turn_deadline) end,
    'set_claim_role',r.set_claim_role,'set_claim_deadline',case when r.set_claim_deadline is null then null else extract(epoch from r.set_claim_deadline) end,
    'set_pass_streak',r.set_pass_streak
  );
end $$;

create or replace function public.bw_submit_move(p_code text,p_token text,p_number integer)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  r public.bw_rooms%rowtype; v_role text; v_host_n integer; v_guest_n integer;
  v_host_score integer; v_guest_score integer; v_round_winner text; v_final_winner text;
  v_result jsonb; v_history jsonb; v_next_starter text;
begin
  if p_number is null or p_number < 0 then raise exception '포인트는 0 이상이어야 합니다.'; end if;
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host';
  elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest';
  else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.game_mode not in ('bw1','bw2') then raise exception '이 게임에서는 포인트 제시 기능을 사용할 수 없습니다.'; end if;
  if r.status <> 'playing' then raise exception '현재 진행 중인 게임이 아닙니다.'; end if;
  if r.game_mode='bw1' then
    if p_number is null or p_number<0 or p_number>8 then raise exception '0~8 숫자 타일만 선택할 수 있습니다.'; end if;
    if r.starter_role is null then raise exception '먼저 1라운드 선 플레이어를 결정하세요.'; end if;
    if r.host_pending is null and r.guest_pending is null then
      if v_role<>r.starter_role then raise exception '선 플레이어가 먼저 타일을 선택해야 합니다.'; end if;
    elsif r.host_pending is not null and r.guest_pending is null then
      if v_role<>'guest' then raise exception '후 플레이어의 타일 선택을 기다리고 있습니다.'; end if;
    elsif r.guest_pending is not null and r.host_pending is null then
      if v_role<>'host' then raise exception '후 플레이어의 타일 선택을 기다리고 있습니다.'; end if;
    else raise exception '이번 라운드는 이미 처리되었습니다.'; end if;
    if v_role='host' then
      if p_number=any(r.host_used) then raise exception '이미 사용한 타일입니다.'; end if;
      update public.bw_rooms set host_pending=p_number,host_used=array_append(host_used,p_number) where id=r.id returning * into r;
    else
      if p_number=any(r.guest_used) then raise exception '이미 사용한 타일입니다.'; end if;
      update public.bw_rooms set guest_pending=p_number,guest_used=array_append(guest_used,p_number) where id=r.id returning * into r;
    end if;
    if r.host_pending is null or r.guest_pending is null then return jsonb_build_object('ok',true,'resolved',false); end if;
    v_host_n:=r.host_pending; v_guest_n:=r.guest_pending; v_host_score:=r.host_score; v_guest_score:=r.guest_score;
    if v_host_n>v_guest_n then v_host_score:=v_host_score+1; v_round_winner:='host'; v_next_starter:='host';
    elsif v_guest_n>v_host_n then v_guest_score:=v_guest_score+1; v_round_winner:='guest'; v_next_starter:='guest';
    else v_round_winner:='draw'; v_next_starter:=r.starter_role; end if;
    v_result:=jsonb_build_object('phase',r.phase,'round',r.round_no,'host_number',v_host_n,'guest_number',v_guest_n,'winner',v_round_winner,'next_starter',v_next_starter);
    v_history:=r.history || jsonb_build_array(v_result);
    if r.round_no>=9 and v_host_score=v_guest_score then
      update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,host_pending=null,guest_pending=null,host_used='{}',guest_used='{}',phase='tiebreak',round_no=1,starter_role=v_next_starter,status='playing',winner=null where id=r.id;
    elsif r.round_no>=9 then
      v_final_winner:=case when v_host_score>v_guest_score then 'host' else 'guest' end;
      update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,host_pending=null,guest_pending=null,starter_role=v_next_starter,status='finished',winner=v_final_winner where id=r.id;
    else
      update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,host_pending=null,guest_pending=null,starter_role=v_next_starter,round_no=round_no+1 where id=r.id;
    end if;
    return jsonb_build_object('ok',true,'resolved',true);
  end if;
  if r.starter_role is null then raise exception '먼저 1라운드 선 플레이어를 결정하세요.'; end if;
  if r.host_pending is null and r.guest_pending is null then
    if v_role <> r.starter_role then raise exception '선 플레이어가 먼저 포인트를 제시해야 합니다.'; end if;
  elsif r.host_pending is not null and r.guest_pending is null then
    if v_role <> 'guest' then raise exception '후 플레이어의 제시를 기다리고 있습니다.'; end if;
  elsif r.guest_pending is not null and r.host_pending is null then
    if v_role <> 'host' then raise exception '후 플레이어의 제시를 기다리고 있습니다.'; end if;
  else raise exception '이번 라운드는 이미 처리되었습니다.'; end if;

  if v_role='host' then
    if r.host_pending is not null then raise exception '이번 라운드 포인트를 이미 제시했습니다.'; end if;
    if p_number > r.host_points then raise exception '남은 포인트보다 많이 제시할 수 없습니다.'; end if;
    update public.bw_rooms set host_pending=p_number,host_points=host_points-p_number where id=r.id returning * into r;
  else
    if r.guest_pending is not null then raise exception '이번 라운드 포인트를 이미 제시했습니다.'; end if;
    if p_number > r.guest_points then raise exception '남은 포인트보다 많이 제시할 수 없습니다.'; end if;
    update public.bw_rooms set guest_pending=p_number,guest_points=guest_points-p_number where id=r.id returning * into r;
  end if;

  -- 제시는 서버에 비공개로 저장합니다. 상대 제시 숫자는 게임 종료 전 상태 조회에서 반환하지 않습니다.
  if r.host_pending is null or r.guest_pending is null then
    return jsonb_build_object('ok',true,'resolved',false);
  end if;

  v_host_n:=r.host_pending; v_guest_n:=r.guest_pending;
  v_host_score:=r.host_score; v_guest_score:=r.guest_score;
  if v_host_n>v_guest_n then v_host_score:=v_host_score+1; v_round_winner:='host'; v_next_starter:='host';
  elsif v_guest_n>v_host_n then v_guest_score:=v_guest_score+1; v_round_winner:='guest'; v_next_starter:='guest';
  else v_round_winner:='draw'; v_next_starter:=r.starter_role; end if;
  v_result:=jsonb_build_object('phase',r.phase,'round',r.round_no,'host_number',v_host_n,'guest_number',v_guest_n,'winner',v_round_winner,
    'host_points_after',r.host_points,'guest_points_after',r.guest_points,'next_starter',v_next_starter);
  v_history:=r.history || jsonb_build_array(v_result);

  -- 본 게임에서만 5승 선취 시 즉시 종료하고, 연장전은 3라운드를 모두 진행합니다.
  if r.phase='main' and (v_host_score>=5 or v_guest_score>=5) then
    v_final_winner:=case when v_host_score>v_guest_score then 'host' else 'guest' end;
    update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,
      host_pending=null,guest_pending=null,starter_role=v_next_starter,status='finished',winner=v_final_winner where id=r.id;
  -- 본 게임 9라운드 종료
  elsif r.phase='main' and r.round_no>=9 then
    if v_host_score=v_guest_score then
      -- 동점이면 잔여/사용 포인트를 버리고 각각 33포인트로 3라운드 연장
      update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,
        host_pending=null,guest_pending=null,host_points=33,guest_points=33,host_used='{}',guest_used='{}',phase='tiebreak',round_no=1,
        starter_role=v_next_starter,status='playing',winner=null where id=r.id;
    else
      v_final_winner:=case when v_host_score>v_guest_score then 'host' else 'guest' end;
      update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,
        host_pending=null,guest_pending=null,starter_role=v_next_starter,status='finished',winner=v_final_winner where id=r.id;
    end if;
  -- 3라운드 연장 종료; 다시 동점이면 무승부로 처리
  elsif r.phase='tiebreak' and r.round_no>=3 then
    v_final_winner:=case when v_host_score>v_guest_score then 'host' when v_guest_score>v_host_score then 'guest' else 'draw' end;
    update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,
      host_pending=null,guest_pending=null,starter_role=v_next_starter,status='finished',winner=v_final_winner where id=r.id;
  else
    update public.bw_rooms set host_score=v_host_score,guest_score=v_guest_score,history=v_history,last_result=v_result,
      host_pending=null,guest_pending=null,starter_role=v_next_starter,round_no=round_no+1 where id=r.id;
  end if;
  return jsonb_build_object('ok',true,'resolved',true);
end $$;

create or replace function public.bw_bet_submit_plan(p_code text,p_token text,p_order integer[],p_wagers integer[])
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  r public.bw_rooms%rowtype; v_role text; v_other_ready boolean;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host';
  elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest';
  else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.game_mode<>'bw_bet' or r.status='finished' or r.bet_phase<>'setup' then raise exception '타일 순서와 최초 베팅은 게임 시작 전에만 확정할 수 있습니다.'; end if;
  if v_role='host' and r.host_bet_ready or v_role='guest' and r.guest_bet_ready then raise exception '타일 순서와 베팅을 이미 확정했습니다.'; end if;
  if coalesce(array_length(p_order,1),0)<>10 or array_position(p_order,null) is not null
    or exists(select 1 from unnest(p_order) n where n<0 or n>9)
    or (select count(distinct n) from unnest(p_order) n)<>10 then
    raise exception '0부터 9까지의 숫자 타일을 각각 한 번씩 순서대로 제출해야 합니다.';
  end if;
  if coalesce(array_length(p_wagers,1),0)<>10 or array_position(p_wagers,null) is not null
    or exists(select 1 from unnest(p_wagers) n where n<1)
    or (select sum(n) from unnest(p_wagers) n)<>30 then
    raise exception '각 타일에 최소 1칩씩 베팅하고 총 30칩을 모두 배분해야 합니다.';
  end if;
  if v_role='host' then
    v_other_ready:=r.guest_bet_ready;
    update public.bw_rooms set host_bet_order=p_order,host_bet_wagers=p_wagers,host_bet_chips=0,host_bet_ready=true,
      status=case when r.guest_bet_ready then 'playing' else r.status end,
      bet_phase=case when r.guest_bet_ready then 'battle' else 'setup' end
    where id=r.id;
  else
    v_other_ready:=r.host_bet_ready;
    update public.bw_rooms set guest_bet_order=p_order,guest_bet_wagers=p_wagers,guest_bet_chips=0,guest_bet_ready=true,
      status=case when r.host_bet_ready then 'playing' else r.status end,
      bet_phase=case when r.host_bet_ready then 'battle' else 'setup' end
    where id=r.id;
  end if;
  return jsonb_build_object('ok',true,'ready',true,'battle_started',v_other_ready);
end $$;

drop function if exists public.bw_bet_action(text,text,text,integer[]);
drop function if exists public.bw_bet_action(text,text,text,integer,integer[]);
drop function if exists public.bw_bet_action(text,text,text,integer,integer[],integer[]);
drop function if exists public.bw_bet_action(text,text,text,integer,integer[],integer[],integer);
create or replace function public.bw_bet_action(p_code text,p_token text,p_action text,p_round integer,p_recover_tiles integer[] default '{}',p_recover_amounts integer[] default '{}',p_wallet_spend integer default null)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare
  r public.bw_rooms%rowtype;
  v_role text; v_low_role text; v_winner_role text; v_outcome text;
  v_index integer; v_tile integer; v_pos integer; v_take integer; v_need integer; v_wallet integer; v_wallet_spend integer; v_recovery_total integer;
  v_host_stake integer; v_guest_stake integer; v_pot integer;
  v_host_chips integer; v_guest_chips integer; v_host_wagers integer[]; v_guest_wagers integer[];
  v_revealed boolean[]; v_folded boolean[]; v_result jsonb; v_total integer; v_distinct integer;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host';
  elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest';
  else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.game_mode<>'bw_bet' or r.status<>'playing' or r.bet_phase<>'battle'
    or not r.host_bet_ready or not r.guest_bet_ready then
    raise exception '베팅 대결을 진행할 수 있는 상태가 아닙니다.';
  end if;
  if p_round is distinct from r.round_no then return jsonb_build_object('ok',true,'resolved',false,'stale',true); end if;

  v_index:=r.round_no;
  v_host_stake:=r.host_bet_wagers[v_index];
  v_guest_stake:=r.guest_bet_wagers[v_index];
  if v_host_stake is null or v_guest_stake is null then raise exception '현재 순서의 베팅 정보를 찾을 수 없습니다.'; end if;
  if p_action not in ('reveal','match','fold') then raise exception '알 수 없는 베팅 동작입니다.'; end if;

  if p_action='reveal' and v_host_stake<>v_guest_stake then
    return jsonb_build_object('ok',true,'resolved',false);
  end if;
  if p_action in ('match','fold') then
    if v_host_stake=v_guest_stake then raise exception '같은 칩을 베팅한 타일은 바로 공개됩니다.'; end if;
    v_low_role:=case when v_host_stake<v_guest_stake then 'host' else 'guest' end;
    if v_role<>v_low_role then raise exception '칩을 적게 베팅한 플레이어만 매치 또는 포기를 선택할 수 있습니다.'; end if;
  end if;

  v_host_chips:=r.host_bet_chips; v_guest_chips:=r.guest_bet_chips;
  v_host_wagers:=r.host_bet_wagers; v_guest_wagers:=r.guest_bet_wagers;
  v_revealed:=r.bet_revealed; v_folded:=r.bet_folded;

  if p_action='match' then
    v_need:=abs(v_host_stake-v_guest_stake);
    v_wallet:=case when v_low_role='host' then v_host_chips else v_guest_chips end;
    v_recovery_total:=0;
    if cardinality(coalesce(p_recover_tiles,'{}'::integer[]))<>cardinality(coalesce(p_recover_amounts,'{}'::integer[])) then
      raise exception '회수할 타일과 칩 개수를 함께 지정해야 합니다.';
    end if;
    if cardinality(coalesce(p_recover_tiles,'{}'::integer[]))<>(select count(distinct n) from unnest(coalesce(p_recover_tiles,'{}'::integer[])) n) then
      raise exception '회수할 타일을 중복 선택할 수 없습니다.';
    end if;
    for v_pos in 1..cardinality(coalesce(p_recover_tiles,'{}'::integer[])) loop
      v_tile:=p_recover_tiles[v_pos];
      v_take:=p_recover_amounts[v_pos];
      if v_tile<1 or v_tile>10 or v_tile<=v_index then raise exception '회수할 타일은 아직 승부하지 않은 타일만 선택할 수 있습니다.'; end if;
      if v_take is null or v_take<1 then raise exception '회수할 칩 개수는 타일별로 1개 이상 지정해야 합니다.'; end if;
      if v_low_role='host' then
        if v_host_wagers[v_tile] is null or v_take>v_host_wagers[v_tile]-1 then raise exception '회수 후 해당 타일에는 최소 1칩을 남겨야 합니다.'; end if;
      else
        if v_guest_wagers[v_tile] is null or v_take>v_guest_wagers[v_tile]-1 then raise exception '회수 후 해당 타일에는 최소 1칩을 남겨야 합니다.'; end if;
      end if;
      v_recovery_total:=v_recovery_total+v_take;
    end loop;
    v_wallet_spend:=coalesce(p_wallet_spend,least(v_wallet,v_need));
    if v_wallet_spend<0 or v_wallet_spend>least(v_wallet,v_need) then
      raise exception '사용할 보유 칩 수는 0개 이상이며 보유 칩과 부족분을 넘을 수 없습니다.';
    end if;
    v_need:=v_need-v_wallet_spend;
    if v_recovery_total<>v_need then raise exception '보유 칩 사용 후 타일별 회수 칩 합계는 %칩과 같아야 합니다.',v_need; end if;
    if v_low_role='host' then v_host_chips:=v_host_chips-v_wallet_spend; else v_guest_chips:=v_guest_chips-v_wallet_spend; end if;
    for v_pos in 1..cardinality(coalesce(p_recover_tiles,'{}'::integer[])) loop
      v_tile:=p_recover_tiles[v_pos];
      v_take:=p_recover_amounts[v_pos];
      if v_low_role='host' then v_host_wagers[v_tile]:=v_host_wagers[v_tile]-v_take; else v_guest_wagers[v_tile]:=v_guest_wagers[v_tile]-v_take; end if;
    end loop;
    if v_low_role='host' then v_host_stake:=v_guest_stake; else v_guest_stake:=v_host_stake; end if;
    v_host_wagers[v_index]:=v_host_stake; v_guest_wagers[v_index]:=v_guest_stake;
  end if;

  if p_action='fold' then
    v_winner_role:=case when v_host_stake>v_guest_stake then 'host' else 'guest' end;
    v_outcome:='fold';
    v_folded[v_index]:=true;
  else
    v_revealed[v_index]:=true;
    if r.host_bet_order[v_index]>r.guest_bet_order[v_index] then v_winner_role:='host';
    elsif r.guest_bet_order[v_index]>r.host_bet_order[v_index] then v_winner_role:='guest';
    else v_winner_role:='draw'; end if;
    v_outcome:=case when v_winner_role='draw' then 'draw' else 'match' end;
  end if;

  v_pot:=v_host_stake+v_guest_stake;
  if v_winner_role='draw' then
    v_host_chips:=v_host_chips+v_host_stake;
    v_guest_chips:=v_guest_chips+v_guest_stake;
  elsif v_winner_role='host' then v_host_chips:=v_host_chips+v_pot;
  else v_guest_chips:=v_guest_chips+v_pot; end if;
  v_host_wagers[v_index]:=0; v_guest_wagers[v_index]:=0;

  v_result:=jsonb_build_object(
    'round',v_index,'outcome',v_outcome,'winner',v_winner_role,'opened',p_action<>'fold',
    'host_tile',case when p_action<>'fold' then r.host_bet_order[v_index] else null end,
    'guest_tile',case when p_action<>'fold' then r.guest_bet_order[v_index] else null end,
    'host_wager',v_host_stake,'guest_wager',v_guest_stake,'chips_awarded',case when v_winner_role='draw' then 0 else v_pot end
  );
  v_index:=v_index+1;
  if v_index>10 then
    v_total:=v_host_chips+coalesce((select sum(n) from unnest(v_host_wagers) n),0);
    if v_total>v_guest_chips+coalesce((select sum(n) from unnest(v_guest_wagers) n),0) then v_winner_role:='host';
    elsif v_total<v_guest_chips+coalesce((select sum(n) from unnest(v_guest_wagers) n),0) then v_winner_role:='guest';
    else v_winner_role:='draw'; end if;
    update public.bw_rooms set host_bet_chips=v_host_chips,guest_bet_chips=v_guest_chips,
      host_bet_wagers=v_host_wagers,guest_bet_wagers=v_guest_wagers,bet_revealed=v_revealed,bet_folded=v_folded,
      bet_history=bet_history||jsonb_build_array(v_result),status='finished',bet_phase='finished',winner=v_winner_role,
      host_score=v_host_chips+coalesce((select sum(n) from unnest(v_host_wagers) n),0),
      guest_score=v_guest_chips+coalesce((select sum(n) from unnest(v_guest_wagers) n),0)
    where id=r.id;
  else
    update public.bw_rooms set host_bet_chips=v_host_chips,guest_bet_chips=v_guest_chips,
      host_bet_wagers=v_host_wagers,guest_bet_wagers=v_guest_wagers,bet_revealed=v_revealed,bet_folded=v_folded,
      bet_history=bet_history||jsonb_build_array(v_result),round_no=v_index
    where id=r.id;
  end if;
  return jsonb_build_object('ok',true,'resolved',true,'round',v_index-1,'winner',v_result->'winner');
end $$;

create or replace function public.bw_set_reaction(p_code text,p_token text,p_message text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare r public.bw_rooms%rowtype; v_role text; v_message text;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token=r.host_token then v_role:='host'; elsif p_token=r.guest_token and r.guest_token is not null then v_role:='guest'; else raise exception '이 방의 참가자 토큰이 아닙니다.'; end if;
  if r.status<>'playing' then raise exception '게임 중에만 감정 표현을 사용할 수 있습니다.'; end if;
  if p_message not in ('😄','😠','😢','😱','🎉','👏') then raise exception '지원하지 않는 감정 표현입니다.'; end if;
  if v_role='host' then update public.bw_rooms set host_reaction=jsonb_build_object('message',p_message,'until',now()+interval '4 seconds') where id=r.id;
  else update public.bw_rooms set guest_reaction=jsonb_build_object('message',p_message,'until',now()+interval '4 seconds') where id=r.id; end if;
  return jsonb_build_object('ok',true);
end $$;

create or replace function public.bw_restart_game(p_code text,p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions,pg_temp as $$
declare r public.bw_rooms%rowtype;
begin
  select * into r from public.bw_rooms where code=upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없습니다.'; end if;
  if p_token is distinct from r.host_token then raise exception '방장만 게임을 다시 시작할 수 있습니다.'; end if;
  if r.status<>'finished' then raise exception '게임이 종료된 뒤에만 다시 시작할 수 있습니다.'; end if;
  if r.guest_token is null then raise exception '상대가 참가한 방에서만 다시 시작할 수 있습니다.'; end if;

  update public.bw_rooms set
    status='playing',round_no=1,phase='main',starter_role=null,challenged_role='host',
    host_score=0,guest_score=0,
    host_points=case when game_mode='bw2' then 99 else 0 end,
    guest_points=case when game_mode='bw2' then 99 else 0 end,
    host_used='{}',guest_used='{}',host_pending=null,guest_pending=null,
    history='[]'::jsonb,last_result=null,winner=null,
    host_reaction=null,guest_reaction=null,
    bet_phase='setup',host_bet_ready=false,guest_bet_ready=false,
    host_bet_order='{}',guest_bet_order='{}',host_bet_wagers='{}',guest_bet_wagers='{}',
    host_bet_chips=30,guest_bet_chips=30,
    bet_revealed=array_fill(false,array[10]),bet_folded=array_fill(false,array[10]),
    bet_history='[]'::jsonb,
    set_board='{}',set_found_sets='[]'::jsonb,set_events='[]'::jsonb,set_turn_role=null,
    set_turn_deadline=null,set_claim_role=null,set_claim_deadline=null,set_pass_streak=0
  where id=r.id;
  return jsonb_build_object('ok',true,'starter_picker','host');
end $$;

revoke all on function public.bw_create_room(text,text,text,text) from public;
revoke all on function public.bw_join_room(text,text,text) from public;
revoke all on function public.bw_choose_starter(text,text,text) from public;
revoke all on function public.bw_get_state(text,text) from public;
revoke all on function public.bw_submit_move(text,text,integer) from public;
revoke all on function public.bw_bet_submit_plan(text,text,integer[],integer[]) from public;
revoke all on function public.bw_bet_action(text,text,text,integer,integer[],integer[],integer) from public;
revoke all on function public.bw_set_reaction(text,text,text) from public;
revoke all on function public.bw_restart_game(text,text) from public;
revoke all on function public.bw_set_is_valid(integer,integer,integer) from public;
revoke all on function public.bw_set_board_has_unfound(integer[],jsonb) from public;
revoke all on function public.bw_set_finish_round(text,text) from public;
revoke all on function public.bw_set_action(text,text,text,integer[]) from public;
grant execute on function public.bw_create_room(text,text,text,text) to anon,authenticated;
grant execute on function public.bw_join_room(text,text,text) to anon,authenticated;
grant execute on function public.bw_choose_starter(text,text,text) to anon,authenticated;
grant execute on function public.bw_get_state(text,text) to anon,authenticated;
grant execute on function public.bw_submit_move(text,text,integer) to anon,authenticated;
grant execute on function public.bw_bet_submit_plan(text,text,integer[],integer[]) to anon,authenticated;
grant execute on function public.bw_bet_action(text,text,text,integer,integer[],integer[],integer) to anon,authenticated;
grant execute on function public.bw_set_reaction(text,text,text) to anon,authenticated;
grant execute on function public.bw_restart_game(text,text) to anon,authenticated;
grant execute on function public.bw_set_action(text,text,text,integer[]) to anon,authenticated;
