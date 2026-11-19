-- 냉장고를 부탁해 · 전체 테이블 생성 스크립트 (dev DB 기준 DDL + 구매 확정 outbox)
-- 테이블 43개: dev DB에서 뽑은 DDL을 그대로 옮겼다(참조되는 테이블이 먼저 오는 순서).
-- 마지막 1개: 구매 확정 이벤트 outbox(order_outbox_events). 이미 테이블이 있는 DB에는 docs/database/history/order-outbox-events.sql만 실행한다.
-- 실행: 빈 DB에 한 번 (예: mysql -u fridge_user -p fridge_db < fridge-db-schema.sql)

create table daily_sales
(
    id              bigint auto_increment comment '일별 매출 ID'
        primary key,
    sales_date      date                                     not null comment '매출 날짜 (한국 시간 기준)',
    paid_amount     bigint      default 0                    not null comment '결제 금액 합계 (결제 완료일 기준)',
    refunded_amount bigint      default 0                    not null comment '환불 금액 합계 (환불 완료일 기준, 부분 환불 포함)',
    net_amount      bigint as ((`paid_amount` - `refunded_amount`)) stored comment '순매출 (결제 금액 − 환불 금액, 자동 계산)',
    paid_count      int         default 0                    not null comment '결제 건수',
    refunded_count  int         default 0                    not null comment '환불 건수 (부분 환불도 1건)',
    created_at      datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성 일시 (최초 집계 시각)',
    updated_at      datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정 일시 (마지막 집계 시각)',
    constraint uk_daily_sales_sales_date
        unique (sales_date)
)
    comment '일별 매출 정산';

create table forecast_batch_runs
(
    id                bigint auto_increment
        primary key,
    created_at        datetime(6)                                                                        not null,
    updated_at        datetime(6)                                                                        null,
    attempted_at      datetime(6)                                                                        not null,
    failure_type      varchar(100)                                                                       null,
    status            enum ('ALREADY_EXISTS', 'CREATED', 'FAILED', 'NO_PRODUCTS', 'NO_TRAINING_SAMPLES') not null,
    target_week_start date                                                                               not null,
    constraint uk_forecast_batch_runs_target_week_start
        unique (target_week_start)
);

create table ingredients
(
    id                 bigint auto_increment comment '표준 재료 ID'
        primary key,
    ingredient_code    varchar(50)                                  not null comment '표준 재료 코드 (예: ING_EGG, ING_CUSTOM, ING_MEALKIT)',
    name               varchar(100)                                 not null comment '대표 명칭 (예: 계란)',
    base_unit          varchar(20)                                  not null comment '기본 단위 (예: 개, 대, 모, g, ml. 냉장고·레시피·상품 수량은 모두 이 단위 기준)',
    default_storage    enum ('REFRIGERATED', 'FROZEN', 'ROOM_TEMP') not null comment '권장 보관 방식 (냉장/냉동/실온)',
    default_shelf_days int         default 0                        not null comment '권장 보관 일수 (등록일 + 일수 = 소비기한)',
    is_basic_seasoning tinyint(1)  default 0                        not null comment '기본 양념 여부 (요리 완료 차감·임박 재료 추천에서 제외)',
    created_at         datetime(6) default CURRENT_TIMESTAMP(6)     not null comment '생성일시',
    updated_at         datetime(6) default CURRENT_TIMESTAMP(6)     not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    unit_weight_g      decimal(8, 2)                                null,
    constraint uk_ingredients_ingredient_code
        unique (ingredient_code),
    constraint uk_ingredients_name
        unique (name)
)
    comment '표준 재료 사전 (동의어는 Elasticsearch에서 관리)';

create table members
(
    id            bigint auto_increment comment '회원 ID'
        primary key,
    email         varchar(255)                             not null comment '로그인 이메일',
    password_hash varchar(255)                             not null comment '비밀번호 해시(복원 불가)',
    nickname      varchar(30)                              not null comment '닉네임(후기 표시 이름)',
    role          enum ('ADMIN', 'USER')                   not null,
    status        enum ('ACTIVE', 'SUSPENDED')             not null,
    created_at    datetime(6) default CURRENT_TIMESTAMP(6) not null comment '가입일시',
    updated_at    datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    phone         varchar(11)                              null,
    constraint uk_members_email
        unique (email),
    constraint uk_members_nickname
        unique (nickname),
    constraint uk_members_phone
        unique (phone)
)
    comment '회원';

create table admin_audit_logs
(
    id           bigint auto_increment comment '작업 이력 ID'
        primary key,
    member_id    bigint                                                                                                                    not null comment '작업한 회원 ID(권한 없이 시도한 일반 회원 포함)',
    action       enum ('DEAL_ANALYSIS', 'DEAL_REVIEW', 'EVENT_REQUEST', 'PRICE_UPDATE', 'PRODUCT_CREATE', 'PRODUCT_DELETE', 'ROLE_CHANGE') not null,
    target_type  varchar(50)                                                                                                               not null comment '작업 대상 종류(Product, DealCandidate, Member 등)',
    target_id    bigint                                                                                                                    null comment '작업 대상 ID(등록 실패처럼 대상이 없으면 NULL)',
    result       enum ('DENIED', 'FAILED', 'SUCCESS')                                                                                      not null,
    before_value json                                                                                                                      null comment '변경 전 값',
    after_value  json                                                                                                                      null comment '변경 후 값',
    created_at   datetime(6) default CURRENT_TIMESTAMP(6)                                                                                  not null comment '작업일시',
    updated_at   datetime(6) default CURRENT_TIMESTAMP(6)                                                                                  not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    actor_role   enum ('ADMIN', 'USER')                                                                                                    null,
    constraint fk_admin_audit_logs_member
        foreign key (member_id) references members (id)
)
    comment '관리자 작업 이력';

create table billing_keys
(
    id                     bigint auto_increment comment '등록 카드 ID'
        primary key,
    member_id              bigint                                   not null comment '카드 주인 회원 ID',
    billing_key_ciphertext varchar(512)                             not null comment 'PortOne 빌링키 AES-256-GCM 암호문(v1:{키ID}:{Base64}). 응답으로 내려주지 않음',
    billing_key_hash       char(64)                                 not null,
    card_name              varchar(100)                             null comment '카드 상품명(PortOne 빌링키 조회 card.name)',
    card_last4             char(4)                                  null,
    card_number_masked     varchar(30)                              null comment '마스킹된 카드 번호(PortOne card.number). 같은 카드 중복 등록 확인용',
    card_issuer_code       varchar(30)                              null comment '카드 발급사 코드(PortOne card.issuer). 같은 카드 중복 등록 확인용',
    card_type              enum ('CREDIT', 'DEBIT', 'GIFT')         null,
    is_default             tinyint(1)  default 0                    not null comment '대표 카드 여부(회원당 사용 중 카드 중 하나)',
    status                 enum ('ACTIVE', 'DELETED')               not null,
    deleted_at             datetime(6)                              null comment '삭제 시각',
    pg_deleted_at          datetime(6)                              null comment 'PortOne 빌링키 삭제 확인 시각. 삭제 상태인데 NULL이면 재시도 대상',
    created_at             datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시(등록 시각)',
    updated_at             datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_billing_keys_billing_key_hash
        unique (billing_key_hash),
    constraint fk_billing_keys_member
        foreign key (member_id) references members (id)
)
    comment '등록 카드';

create index idx_billing_keys_member_status
    on billing_keys (member_id, status);

create index idx_billing_keys_status_pg_deleted_at
    on billing_keys (status, pg_deleted_at);

create table carts
(
    id         bigint auto_increment comment '장바구니 ID'
        primary key,
    member_id  bigint                                   not null comment '회원 ID (회원 한 명에 장바구니 하나)',
    created_at datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_carts_member_id
        unique (member_id),
    constraint fk_carts_member
        foreign key (member_id) references members (id)
)
    comment '장바구니 (회원이 처음 상품을 담을 때 생성)';

create table chat_sessions
(
    id              bigint auto_increment comment '상담 세션 ID'
        primary key,
    member_id       bigint                                                               not null comment '회원 ID',
    status          enum ('ACTIVE', 'COMPLETED', 'EXPIRED') default 'ACTIVE'             not null comment '세션 상태 (진행 중/요리 완료로 종료/시간 초과로 만료. 종료된 세션은 다시 열리지 않음)',
    last_message_at datetime(6)                             default CURRENT_TIMESTAMP(6) not null comment '마지막 대화 일시',
    created_at      datetime(6)                             default CURRENT_TIMESTAMP(6) not null comment '생성일시 (상담 시작 시각)',
    updated_at      datetime(6)                             default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint fk_chat_sessions_member
        foreign key (member_id) references members (id)
)
    comment 'AI 냉장고 상담 세션';

create table chat_messages
(
    id              bigint auto_increment comment '메시지 ID'
        primary key,
    chat_session_id bigint                                   not null comment '상담 세션 ID',
    sequence        int         default 0                    not null comment '세션 안 메시지 순서 (1부터 증가)',
    role            enum ('USER', 'ASSISTANT')               not null comment '보낸 쪽 (사용자/AI)',
    content         text                                     not null comment '메시지 원문 (AI는 상세 조리법 전체)',
    created_at      datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at      datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    filtered        bit                                      not null,
    constraint uk_chat_messages_chat_session_id_sequence
        unique (chat_session_id, sequence),
    constraint fk_chat_messages_chat_session
        foreign key (chat_session_id) references chat_sessions (id)
)
    comment 'AI 상담 메시지 내역';

create index idx_chat_sessions_member_id_last_message_at
    on chat_sessions (member_id, last_message_at);

create index idx_chat_sessions_member_id_status
    on chat_sessions (member_id, status);

create index idx_chat_sessions_status_last_message_at
    on chat_sessions (status, last_message_at);

create table deal_analyses
(
    id                bigint auto_increment comment '할인 후보 분석 ID'
        primary key,
    member_id         bigint                                                 not null comment '분석한 관리자 회원 ID',
    target_week_start date                                                   not null comment '대상 주 시작일(월요일)',
    day_of_week       enum ('MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN') not null comment '적용 요일',
    discount_rate     int         default 0                                  not null comment '가상 할인율(%, 10~40)',
    min_stock         int         default 50                                 not null comment '최소 재고 기준(개)',
    model_version     varchar(50)                                            not null comment '분석 모델 버전',
    data_cutoff_at    datetime(6)                                            not null comment '입력 데이터 기준 시각',
    last_saved_at     datetime(6)                                            null comment '검토 결과 마지막 저장일시',
    created_at        datetime(6) default CURRENT_TIMESTAMP(6)               not null comment '분석일시',
    updated_at        datetime(6) default CURRENT_TIMESTAMP(6)               not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    synthetic_data    bit                                                    not null,
    constraint fk_deal_analyses_member
        foreign key (member_id) references members (id)
)
    comment '요일별 할인 후보 분석';

create table deal_candidates
(
    id                    bigint auto_increment comment '분석 결과 상품 ID'
        primary key,
    deal_analysis_id      bigint                                                                          not null comment '할인 후보 분석 ID',
    product_id            bigint                                                                          not null comment '상품 ID(상품 도메인, 외래키 없음)',
    product_name          varchar(100)                                                                    not null,
    regular_price         int                                                default 0                    not null comment '분석 당시 정상가(원)',
    discount_price        int                                                default 0                    not null comment '가상 할인가(원)',
    current_stock         int                                                default 0                    not null comment '분석 당시 재고(개)',
    avg_sales_on_day      int                                                default 0                    not null comment '해당 요일 평균 판매량',
    search_clicks         int                                                default 0                    not null comment '최근 4주 같은 요일 검색 클릭 수',
    purchases             int                                                default 0                    not null comment '최근 4주 같은 요일 구매 수',
    is_excluded           tinyint(1)                                         default 0                    not null comment '후보 제외 여부(TRUE면 제외된 상품)',
    exclude_reason        enum ('TOP_SELLER_ON_DAY', 'LOW_STOCK')                                         null comment '제외 사유(평소 그 요일 판매 상위/재고 부족)',
    candidate_reason      varchar(255)                                                                    null comment '후보 사유(예: 검색 클릭 대비 구매 적음)',
    expected_qty_regular  int                                                                             null comment '정상가일 때 예상 판매 수량(후보만)',
    expected_qty_discount int                                                                             null comment '할인가일 때 예상 판매 수량(후보만)',
    expected_increase     int                                                                             null comment '예상 판매 증가량(후보만)',
    review_status         enum ('UNREVIEWED', 'SELECTED', 'HELD')                                         null comment '관리자 검토 상태(미검토/선택/보류, 후보만)',
    event_request_status  enum ('NONE', 'REQUESTED', 'APPROVED', 'REJECTED') default 'NONE'               not null comment '할인 행사 등록 요청 상태',
    event_requested_at    datetime(6)                                                                     null comment '할인 행사 등록 요청일시',
    promotion_id          bigint                                                                          null comment '등록된 할인 행사 ID(할인 행사 도메인, 외래키 없음)',
    created_at            datetime(6)                                        default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at            datetime(6)                                        default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_deal_candidates_analysis_product
        unique (deal_analysis_id, product_id),
    constraint fk_deal_candidates_deal_analysis
        foreign key (deal_analysis_id) references deal_analyses (id)
)
    comment '할인 후보 분석 결과 상품(후보·제외)';

create table member_tastes
(
    id         bigint auto_increment comment '맛 선호 ID'
        primary key,
    member_id  bigint                                            not null comment '회원 ID',
    taste      enum ('MILD', 'SALTY', 'SPICY', 'SWEET', 'UMAMI') not null,
    created_at datetime(6) default CURRENT_TIMESTAMP(6)          not null comment '생성일시',
    updated_at datetime(6) default CURRENT_TIMESTAMP(6)          not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_member_tastes_member_taste
        unique (member_id, taste),
    constraint fk_member_tastes_member
        foreign key (member_id) references members (id)
)
    comment '회원 맛 선호';

create table notifications
(
    id                bigint auto_increment comment '알림 ID'
        primary key,
    member_id         bigint                                                not null comment '받는 회원 ID',
    notification_type enum ('EXPIRATION', 'FLASH_DROP', 'COMMERCE_STOCKED') not null comment '알림 종류 (소비기한 임박/번개 드롭/커머스 자동 입고)',
    content           varchar(200)                                          not null comment '알림 문구 (예: 두부 소비기한이 3일 남았어요)',
    link_url          varchar(500)                                          not null comment '알림 클릭 시 이동 경로 (예: /fridge)',
    dedupe_key        varchar(150)                                          not null comment '중복 방지 키 (예: EXPIRATION:123:2026-10-14)',
    is_read           tinyint(1)  default 0                                 not null comment '읽음 여부',
    created_at        datetime(6) default CURRENT_TIMESTAMP(6)              not null comment '생성일시',
    updated_at        datetime(6) default CURRENT_TIMESTAMP(6)              not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    deleted_at        datetime(6)                                           null,
    constraint uk_notifications_member_id_dedupe_key
        unique (member_id, dedupe_key),
    constraint fk_notifications_member
        foreign key (member_id) references members (id)
)
    comment '인앱 알림 (모든 도메인 공통)';

create index idx_notifications_member_id_is_read
    on notifications (member_id, is_read);

create index idx_notifications_member_id_notification_type_created_at
    on notifications (member_id, notification_type, created_at);

create table orders
(
    id              bigint auto_increment comment '주문 ID'
        primary key,
    order_number    varchar(20)                                                                                 not null comment '주문번호 (날짜 + 일련번호, 예: 20261013-000123)',
    member_id       bigint                                                                                      not null comment '회원 ID',
    status          enum ('PENDING', 'PAID', 'CANCELLED', 'CONFIRMED', 'REFUNDED') default 'PENDING'            not null,
    total_amount    bigint                                                         default 0                    not null comment '결제할 금액 (주문 생성 때 확정)',
    paid_at         datetime(6)                                                                                 null comment '결제 완료 일시 (구매 확정 스케줄러 기준, 결제 전에는 NULL)',
    created_at      datetime(6)                                                    default CURRENT_TIMESTAMP(6) not null comment '생성일시 (5분 자동 취소 기준)',
    updated_at      datetime(6)                                                    default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    confirmed_at    datetime(6)                                                                                 null,
    idempotency_key varchar(64)                                                                                 null,
    constraint uk_orders_member_id_idempotency_key
        unique (member_id, idempotency_key),
    constraint uk_orders_order_number
        unique (order_number),
    constraint fk_orders_member
        foreign key (member_id) references members (id)
)
    comment '주문';

create index idx_orders_member_id_status
    on orders (member_id, status);

create index idx_orders_status_created_at
    on orders (status, created_at);

create index idx_orders_status_paid_at
    on orders (status, paid_at);

create table payment_pins
(
    id           bigint auto_increment comment '결제 비밀번호 ID'
        primary key,
    member_id    bigint                                   not null comment '회원 ID',
    pin_hash     varchar(100)                             not null comment '결제 비밀번호 해시(BCrypt). 원래 값은 저장하지 않음',
    failed_count int         default 0                    not null comment '연속으로 틀린 횟수. 맞히거나 재설정하면 0',
    locked_at    datetime(6)                              null comment '5번 연속 틀려 잠긴 시각. 잠기지 않았으면 NULL',
    created_at   datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시(처음 설정한 시각)',
    updated_at   datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_payment_pins_member_id
        unique (member_id),
    constraint fk_payment_pins_member
        foreign key (member_id) references members (id)
)
    comment '등록 카드 결제 비밀번호';

create table payments
(
    id                 bigint auto_increment comment '결제 ID'
        primary key,
    order_id           bigint                                                                                                not null comment '주문 ID (결제 회원은 주문으로 확인, 한 주문에 결제 시도 여러 건)',
    billing_key_id     bigint                                                                                                null comment '등록 카드 결제면 그 카드 ID (결제창 결제는 NULL)',
    portone_payment_id varchar(100)                                                                                          not null comment '서버가 발급해 포트원에 넘기는 결제 ID (payment- + UUID 32자, 멱등 기준)',
    amount             bigint      default 0                                                                                 not null comment '결제 금액 (서버 계산, 주문 금액)',
    pg_provider        enum ('INICIS', 'KAKAOPAY', 'KICC', 'TOSSPAY', 'TOSSPAYMENTS')                                        not null,
    status             enum ('FAILED', 'PAID', 'READY')                                                                      not null,
    fail_reason        enum ('AMOUNT_MISMATCH', 'ORDER_NOT_PAYABLE', 'PG_FAILED', 'SUPERSEDED', 'TIMEOUT', 'USER_CANCELLED') null,
    expires_at         datetime(6)                                                                                           not null comment '결제 대기 만료 시각 (결제 생성 시각 + 10분, 결제 시도마다 따로 정함)',
    paid_at            datetime(6)                                                                                           null comment '결제 완료 시각',
    created_at         datetime(6) default CURRENT_TIMESTAMP(6)                                                              not null comment '생성 일시',
    updated_at         datetime(6) default CURRENT_TIMESTAMP(6)                                                              not null on update CURRENT_TIMESTAMP(6) comment '수정 일시',
    constraint uk_payments_portone_payment_id
        unique (portone_payment_id),
    constraint fk_payments_billing_key
        foreign key (billing_key_id) references billing_keys (id),
    constraint fk_payments_order
        foreign key (order_id) references orders (id)
)
    comment '결제';

create table payment_histories
(
    id                 bigint auto_increment comment '결제 이력 ID'
        primary key,
    payment_id         bigint                                                             not null comment '결제 ID',
    event_type         enum ('CANCELLED', 'FAILED', 'PAID', 'PARTIAL_CANCELLED', 'READY') not null,
    amount             bigint                                                             null comment '이번 사건 금액 (결제·취소 금액, 실패는 NULL)',
    cancelled_amount   bigint      default 0                                              not null comment '이 사건 직후 누적 취소 금액',
    refund_id          bigint                                                             null comment '환불로 생긴 취소면 환불 ID (보상·콘솔 취소는 NULL)',
    pg_cancellation_id varchar(200)                                                       null comment 'PG 취소 건 ID',
    changed_by         enum ('SCHEDULER', 'USER', 'WEBHOOK')                              not null,
    reason             varchar(255)                                                       null comment '사유 (결제 대기 만료, 금액 불일치, PG 거절, 보상 취소, 단순 변심 환불 등)',
    created_at         datetime(6) default CURRENT_TIMESTAMP(6)                           not null comment '생성 일시 (사건 시각)',
    updated_at         datetime(6) default CURRENT_TIMESTAMP(6)                           not null on update CURRENT_TIMESTAMP(6) comment '수정 일시',
    constraint fk_payment_histories_payment
        foreign key (payment_id) references payments (id)
)
    comment '결제 이력 (상태 변경과 PG 취소 사건)';

create index idx_payment_histories_created_at
    on payment_histories (created_at);

create index idx_payment_histories_payment_id
    on payment_histories (payment_id, created_at);

create index idx_payment_histories_refund_id
    on payment_histories (refund_id);

create index idx_payments_billing_key_id
    on payments (billing_key_id);

create index idx_payments_order_id
    on payments (order_id);

create index idx_payments_paid_at
    on payments (paid_at);

create index idx_payments_status_expires_at
    on payments (status, expires_at);

create table prediction_runs
(
    id                bigint auto_increment comment '예측 실행 ID'
        primary key,
    target_week_start date                                     not null comment '예측 대상 주 시작일(월요일)',
    model_version     varchar(50)                              not null comment '예측 모델 버전(예: fc-v0.3)',
    data_cutoff_at    datetime(6)                              not null comment '입력 데이터 기준 시각',
    confirmed_at      datetime(6)                              null comment '실제 판매량 확정일시(다음 주 월요일 06:00)',
    created_at        datetime(6) default CURRENT_TIMESTAMP(6) not null comment '예측 생성일시(일요일 22:00)',
    updated_at        datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    synthetic_data    bit                                      not null,
    constraint uk_prediction_runs_target_week_start
        unique (target_week_start)
)
    comment '주간 판매 예측 실행';

create table products
(
    id           bigint auto_increment comment '상품 ID'
        primary key,
    product_type enum ('INGREDIENT', 'MEALKIT')                                       not null comment '상품 종류 (INGREDIENT: 재료 / MEALKIT: 밀키트)',
    name         varchar(200)                                                         not null comment '상품명',
    description  text                                                                 null comment '상품 설명',
    image_url    varchar(500)                                                         null comment '상품 이미지 URL',
    price        int                                     default 0                    not null comment '판매가(원)',
    stock        int                                     default 0                    not null comment '재고 수량',
    storage      enum ('REFRIGERATED', 'FROZEN', 'ROOM_TEMP')                         not null comment '보관 방식 (냉장/냉동/실온)',
    shelf_days   int                                     default 0                    not null comment '권장 보관 일수 (구매 확정일 + 일수 = 냉장고 소비기한)',
    status       enum ('ON_SALE', 'SOLD_OUT', 'STOPPED') default 'ON_SALE'            not null comment '판매 상태 (ON_SALE: 판매 중 / SOLD_OUT: 품절 / STOPPED: 판매 중지)',
    created_at   datetime(6)                             default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at   datetime(6)                             default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint chk_products_price
        check (`price` >= 0),
    constraint chk_products_stock
        check (`stock` >= 0)
)
    comment '판매 상품 공통 정보';

create table cart_items
(
    id         bigint auto_increment comment '장바구니 상품 ID'
        primary key,
    cart_id    bigint                                   not null comment '장바구니 ID',
    product_id bigint                                   not null comment '상품 ID',
    quantity   int         default 1                    not null comment '수량 (1 이상)',
    created_at datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_cart_items_cart_id_product_id
        unique (cart_id, product_id),
    constraint fk_cart_items_cart
        foreign key (cart_id) references carts (id),
    constraint fk_cart_items_product
        foreign key (product_id) references products (id)
)
    comment '장바구니 상품 (가격·재고는 저장하지 않고 조회할 때 읽음)';

create table ingredient_products
(
    id            bigint auto_increment comment '재료 상품 ID'
        primary key,
    product_id    bigint         not null comment '상품 ID',
    ingredient_id bigint         not null comment '재료 ID',
    unit_amount   decimal(8, 2)  not null comment '용량 수치 (300)',
    unit          varchar(20)    not null comment '용량 단위 (g, ml, 개, 팩…)',
    base_quantity decimal(10, 2) not null comment '그 상품이 그 단위로 몇 개인지 (단위당 갯수)',
    constraint uk_ingredient_products_product_id
        unique (product_id),
    constraint fk_ingredient_products_ingredient
        foreign key (ingredient_id) references ingredients (id),
    constraint fk_ingredient_products_product
        foreign key (product_id) references products (id),
    constraint chk_ingredient_products_unit_amount
        check (`unit_amount` > 0)
)
    comment '재료 상품 상세. 재료 마스터 1개에 여러 상품(용량/산지별)이 붙는다';

create index idx_ingredient_products_ingredient_id
    on ingredient_products (ingredient_id);

create table mealkit_products
(
    id         bigint auto_increment comment '밀키트 상품 ID'
        primary key,
    product_id bigint        not null comment '상품 ID',
    servings   int default 1 not null comment '구성 인분',
    recipe_id  bigint        null,
    constraint uk_mealkit_products_product_id
        unique (product_id),
    constraint fk_mealkit_products_product
        foreign key (product_id) references products (id),
    constraint chk_mealkit_products_servings
        check (`servings` > 0)
)
    comment '밀키트 상품 상세';

create index idx_mealkit_products_recipe_id
    on mealkit_products (recipe_id);

create index idx_products_status
    on products (status);

create table recipes
(
    id                       bigint auto_increment comment '레시피 ID'
        primary key,
    source                   varchar(20)                              not null comment '출처 (MAFRA: 농식품 레시피 / MFDS: 식약처 COOKRCP01)',
    source_id                varchar(20)                              not null comment '원본 레시피 코드',
    name                     varchar(200)                             not null comment '레시피 이름',
    summary                  text                                     null comment '간략 소개',
    cuisine_type             varchar(20)                              null comment '음식 종류 (한식/서양/중국…)',
    category                 varchar(50)                              null comment '요리 분류 (밥/국/반찬…)',
    cook_method              varchar(20)                              null comment '조리 방법 (끓이기/굽기…)',
    main_ingredient_category varchar(30)                              null comment '재료별 분류',
    cook_time_min            int                                      null comment '조리시간(분)',
    servings                 int                                      null comment '분량(인분)',
    difficulty               tinyint                                  not null comment '난이도 1(쉬움)~10(어려움). 단계 수/재료 수/조리시간/기법으로 계산',
    weight_g                 decimal(8, 2)                            null comment '1인분 중량(g)',
    calories                 decimal(8, 2)                            null comment '열량(kcal)',
    carbs_g                  decimal(8, 2)                            null comment '탄수화물(g)',
    protein_g                decimal(8, 2)                            null comment '단백질(g)',
    fat_g                    decimal(8, 2)                            null comment '지방(g)',
    sodium_mg                decimal(8, 2)                            null comment '나트륨(mg)',
    tags                     varchar(255)                             null comment '해시태그',
    tip                      text                                     null comment '저감 조리법 팁',
    tip_summary              text                                     null comment '후기 요약',
    image_url                varchar(500)                             null comment '대표 이미지 URL',
    ingredients_raw          text                                     null comment '재료 원문 (파싱 전)',
    created_at               datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at               datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_recipes_source_source_id
        unique (source, source_id),
    constraint chk_recipes_difficulty
        check (`difficulty` between 1 and 10)
)
    comment '레시피 기본 정보';

create table chat_recommendations
(
    id              bigint auto_increment comment '추천 ID'
        primary key,
    chat_message_id bigint                                   not null comment '추천이 나온 AI 메시지 ID',
    recipe_id       bigint                                   null comment '추천 레시피 ID (레시피 추천일 때만)',
    product_id      bigint                                   null comment '추천 상품 ID (재료 상품·밀키트 추천일 때만. 종류는 products.product_type)',
    display_order   int         default 0                    not null comment '메시지 안 추천 순서',
    created_at      datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at      datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    description     text                                     null,
    constraint uk_chat_recommendations_chat_message_id_display_order
        unique (chat_message_id, display_order),
    constraint fk_chat_recommendations_chat_message
        foreign key (chat_message_id) references chat_messages (id),
    constraint fk_chat_recommendations_product
        foreign key (product_id) references products (id),
    constraint fk_chat_recommendations_recipe
        foreign key (recipe_id) references recipes (id),
    constraint chk_chat_recommendations_one_target
        check (((`recipe_id` is not null) + (`product_id` is not null)) = 1)
)
    comment 'AI 상담 추천 결과 (레시피 또는 상품 중 하나)';

create table cooking_logs
(
    id              bigint auto_increment comment '요리 기록 ID'
        primary key,
    member_id       bigint                                   not null comment '회원 ID',
    recipe_id       bigint                                   not null comment '레시피 ID',
    chat_session_id bigint                                   null comment 'AI 상담 세션 ID (상담에서 추천받아 요리했을 때만, 아니면 NULL)',
    result          enum ('SUCCESS', 'FAILED')               not null comment '요리 결과 (성공/실패)',
    memo            varchar(50)                              null comment '요리 메모 (선택, 본인만 열람)',
    created_at      datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시 (요리 완료 시각)',
    updated_at      datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint fk_cooking_logs_chat_session
        foreign key (chat_session_id) references chat_sessions (id),
    constraint fk_cooking_logs_member
        foreign key (member_id) references members (id),
    constraint fk_cooking_logs_recipe
        foreign key (recipe_id) references recipes (id)
)
    comment '요리 기록 (요리 완료할 때마다 1건)';

create index idx_cooking_logs_member_id_created_at
    on cooking_logs (member_id, created_at);

create index idx_cooking_logs_member_id_recipe_id_created_at
    on cooking_logs (member_id, recipe_id, created_at);

create index idx_cooking_logs_recipe_id_result_member_id
    on cooking_logs (recipe_id, result, member_id);

create table fridge_item_logs
(
    id             bigint auto_increment comment '재료 이력 ID'
        primary key,
    member_id      bigint                                      not null comment '회원 ID',
    ingredient_id  bigint                                      not null comment '표준 재료 ID',
    cooking_log_id bigint                                      null comment '요리 기록 ID (요리 완료로 사용했을 때만, 그냥 먹거나 버리면 NULL)',
    fridge_id      bigint                                      not null comment '원래 냉장고 재료 ID (참고용, FK 아님. 원본 행은 삭제될 수 있음)',
    raw_name       varchar(200)                                not null comment '사용자 입력 원문 (냉장고 재료에서 복사)',
    quantity       decimal(10, 2) default 0.00                 not null comment '빠진 수량 (단위는 ingredients.base_unit)',
    action         enum ('CONSUMED', 'DISCARDED')              not null comment '처리 구분 (소진/폐기)',
    created_at     datetime(6)    default CURRENT_TIMESTAMP(6) not null comment '생성일시 (재료가 빠진 시각)',
    updated_at     datetime(6)    default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint fk_fridge_item_logs_cooking_log
        foreign key (cooking_log_id) references cooking_logs (id),
    constraint fk_fridge_item_logs_ingredient
        foreign key (ingredient_id) references ingredients (id),
    constraint fk_fridge_item_logs_member
        foreign key (member_id) references members (id)
)
    comment '냉장고 재료 소진·폐기 이력';

create index idx_fridge_item_logs_member_id_created_at
    on fridge_item_logs (member_id, created_at);

create table recipe_ingredients
(
    id            bigint auto_increment comment '레시피 재료 ID'
        primary key,
    recipe_id     bigint                                   not null comment '레시피 ID',
    ingredient_id bigint                                   not null comment '재료 ID',
    seq           int                                      not null comment '레시피 내 순서 (1부터)',
    display_name  varchar(100)                             null comment '레시피에 적힌 재료명 그대로 (다진 마늘)',
    amount        varchar(100)                             null comment '원문 용량 (1/2큰술, 약간, 100g(3개)…)',
    quantity      decimal(10, 2)                           null comment '수량 (기본단위 당)',
    role          varchar(20)                              null comment '재료 역할 (주재료/부재료/양념)',
    group_name    varchar(50)                              null comment '원문 그룹명 (양념장, 고명…)',
    raw_text      varchar(255)                             null comment '파싱 전 항목 원문',
    created_at    datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at    datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_recipe_ingredients_recipe_id_seq
        unique (recipe_id, seq),
    constraint fk_recipe_ingredients_ingredient
        foreign key (ingredient_id) references ingredients (id),
    constraint fk_recipe_ingredients_recipe
        foreign key (recipe_id) references recipes (id)
            on delete cascade
)
    comment '레시피-재료 연결 (N:M). 레시피별 재료 목록과 용량';

create index idx_recipe_ingredients_ingredient_id
    on recipe_ingredients (ingredient_id);

create table recipe_reviews
(
    id         bigint auto_increment comment '후기 ID'
        primary key,
    member_id  bigint                                   not null comment '회원 ID',
    recipe_id  bigint                                   not null comment '레시피 ID',
    rating     int         default 0                    not null comment '별점 (1~5)',
    content    varchar(100)                             not null comment '한 줄 후기 (최대 100자)',
    created_at datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시 (처음 작성한 시각)',
    updated_at datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시 (마지막으로 고친 시각)',
    constraint uk_recipe_reviews_member_id_recipe_id
        unique (member_id, recipe_id),
    constraint fk_recipe_reviews_member
        foreign key (member_id) references members (id),
    constraint fk_recipe_reviews_recipe
        foreign key (recipe_id) references recipes (id),
    constraint chk_recipe_reviews_rating
        check (`rating` between 1 and 5)
)
    comment '레시피 후기 (회원당 레시피 1개, 수정 가능)';

create index idx_recipe_reviews_created_at
    on recipe_reviews (created_at);

create index idx_recipe_reviews_recipe_id_created_at
    on recipe_reviews (recipe_id, created_at);

create table recipe_steps
(
    id          bigint auto_increment comment '조리 단계 ID'
        primary key,
    recipe_id   bigint       not null comment '레시피 ID',
    step_no     int          not null comment '조리 순서 (1부터)',
    description text         not null comment '조리 설명',
    image_url   varchar(500) null comment '단계 이미지 URL',
    tip         text         null comment '단계별 팁',
    constraint uk_recipe_steps_recipe_id_step_no
        unique (recipe_id, step_no),
    constraint fk_recipe_steps_recipe
        foreign key (recipe_id) references recipes (id)
            on delete cascade
)
    comment '레시피 조리 단계';

create table recipe_tastes
(
    id         bigint auto_increment
        primary key,
    created_at datetime(6)                                       not null,
    updated_at datetime(6)                                       null,
    taste      enum ('MILD', 'SALTY', 'SPICY', 'SWEET', 'UMAMI') not null,
    recipe_id  bigint                                            not null,
    constraint uk_recipe_tastes_recipe_id_taste
        unique (recipe_id, taste),
    constraint fk_recipe_tastes_recipe
        foreign key (recipe_id) references recipes (id)
            on delete cascade
);

create index idx_recipe_tastes_taste_recipe_id
    on recipe_tastes (taste, recipe_id);

create index idx_recipes_category
    on recipes (category);

create index idx_recipes_difficulty
    on recipes (difficulty);

create index idx_recipes_name
    on recipes (name);

create table refresh_sessions
(
    id             bigint auto_increment comment '세션 ID'
        primary key,
    member_id      bigint                                   not null comment '회원 ID',
    token_hash     varchar(255)                             not null comment '갱신 토큰 해시',
    keep_logged_in tinyint(1)  default 0                    not null comment '로그인 상태 유지 체크 여부',
    device_info    varchar(255)                             null comment '접속 기기 정보(기기별 로그아웃용)',
    last_used_at   datetime(6) default CURRENT_TIMESTAMP(6) not null comment '마지막 사용일시(30분 미사용 시 만료)',
    expires_at     datetime(6)                              not null comment '만료일시',
    revoked_at     datetime(6)                              null comment '폐기일시(로그아웃·비밀번호 변경 시)',
    created_at     datetime(6) default CURRENT_TIMESTAMP(6) not null comment '로그인일시',
    updated_at     datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_refresh_sessions_token_hash
        unique (token_hash),
    constraint fk_refresh_sessions_member
        foreign key (member_id) references members (id)
)
    comment '로그인 세션';

create table refunds
(
    id                      bigint auto_increment comment '환불 ID'
        primary key,
    payment_id              bigint                                                              not null comment '결제 ID',
    refund_amount           bigint      default 0                                               not null comment '환불 금액',
    reason_type             enum ('CHANGE_OF_MIND', 'ETC', 'NO_LONGER_NEEDED', 'ORDER_MISTAKE') not null,
    reason_detail           varchar(500)                                                        null comment '상세 사유 (선택 입력)',
    status                  enum ('COMPLETED', 'FAILED', 'REQUESTED')                           not null,
    portone_cancellation_id varchar(200)                                                        null comment '포트원 취소 ID',
    fail_reason             varchar(255)                                                        null comment '포트원 취소 실패 사유',
    refunded_at             datetime(6)                                                         null comment '환불 완료 시각 (정산 기준)',
    created_at              datetime(6) default CURRENT_TIMESTAMP(6)                            not null comment '생성 일시',
    updated_at              datetime(6) default CURRENT_TIMESTAMP(6)                            not null on update CURRENT_TIMESTAMP(6) comment '수정 일시',
    constraint fk_refunds_payment
        foreign key (payment_id) references payments (id)
)
    comment '환불';

create index idx_refunds_refunded_at
    on refunds (refunded_at);

create table sale_events
(
    id         bigint auto_increment comment '할인 행사 ID'
        primary key,
    type       enum ('SPECIAL', 'FLASH_DROP')                                     not null comment '구분 (특가/번개 드롭)',
    starts_at  datetime(6)                                                        not null comment '시작 시각',
    ends_at    datetime(6)                                                        not null comment '종료 시각',
    status     enum ('SCHEDULED', 'ACTIVE', 'ENDED') default 'SCHEDULED'          not null comment '상태 (예정/진행 중/종료)',
    created_at datetime(6)                           default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at datetime(6)                           default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    ended_at   datetime(6)                                                        null
)
    comment '할인 행사 (특가·번개 드롭, 기간과 상태는 행사 단위)';

create table sale_event_items
(
    id                 bigint auto_increment comment '할인 행사 상품 ID'
        primary key,
    sale_event_id      bigint                                   not null comment '할인 행사 ID',
    product_id         bigint                                   not null comment '상품 ID',
    sale_price         int         default 0                    not null comment '할인가 (번개 드롭은 번개 드롭가)',
    discount_rate      int         default 0                    not null comment '할인율 (%, 정가 대비. 관리자가 입력하고 서버가 이 값으로 할인가를 계산해 저장)',
    limited_quantity   int                                      null comment '한정 수량 (번개 드롭만, 특가 NULL)',
    remaining_quantity int                                      null comment '남은 수량 (번개 드롭만, 특가 NULL)',
    created_at         datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at         datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    list_price         int                                      not null,
    constraint fk_sale_event_items_product
        foreign key (product_id) references products (id),
    constraint fk_sale_event_items_sale_event
        foreign key (sale_event_id) references sale_events (id)
)
    comment '할인 행사 상품 (정가는 products에서 읽음)';

create table order_items
(
    id                   bigint auto_increment comment '주문 상품 ID'
        primary key,
    order_id             bigint                                                              not null comment '주문 ID',
    product_id           bigint                                                              not null comment '상품 ID',
    product_name         varchar(200)                                                        not null comment '주문 당시 상품명',
    quantity             int                                    default 1                    not null comment '수량',
    list_price           int                                    default 0                    not null comment '주문 당시 정가',
    unit_price           int                                    default 0                    not null comment '실제 단가 (할인가 또는 정가)',
    sale_type            enum ('NONE', 'SPECIAL', 'FLASH_DROP') default 'NONE'               not null comment '할인 구분 (일반/특가/번개 드롭, 번개 드롭은 환불 불가)',
    sale_event_item_id   bigint                                                              null comment '할인 행사 상품 ID (특가·번개 드롭으로 샀을 때만, 일반은 NULL)',
    flash_drop_member_id bigint                                                              null comment '번개 드롭 구매 회원 ID (번개 드롭 줄만, 1인 1개 확인용. 취소하면 NULL)',
    created_at           datetime(6)                            default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at           datetime(6)                            default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    product_image_url    varchar(500)                                                        null,
    confirmed_quantity   int                                                                 null,
    constraint uk_order_items_sale_event_item_id_flash_drop_member_id
        unique (sale_event_item_id, flash_drop_member_id),
    constraint fk_order_items_member
        foreign key (flash_drop_member_id) references members (id),
    constraint fk_order_items_order
        foreign key (order_id) references orders (id),
    constraint fk_order_items_product
        foreign key (product_id) references products (id),
    constraint fk_order_items_sale_event_item
        foreign key (sale_event_item_id) references sale_event_items (id)
)
    comment '주문 상품 (주문 당시 가격 기록)';

create table fridge
(
    id              bigint auto_increment comment '냉장고 재료 ID'
        primary key,
    member_id       bigint                                                   not null comment '회원 ID',
    ingredient_id   bigint                                                   not null comment '표준 재료 ID (사전에 없으면 ING_CUSTOM, 밀키트는 ING_MEALKIT)',
    order_item_id   bigint                                                   null comment '주문 상품 ID (커머스 자동 입고일 때만, 직접 등록은 NULL)',
    raw_name        varchar(200)                                             not null comment '사용자 입력 원문 (커머스 입고는 상품명)',
    quantity        decimal(10, 2)              default 0.00                 not null comment '수량 (단위는 ingredients.base_unit)',
    storage         enum ('REFRIGERATED', 'FROZEN', 'ROOM_TEMP')             not null comment '보관 방식 (냉장/냉동/실온)',
    expiration_date date                                                     not null comment '소비기한',
    source          enum ('MANUAL', 'COMMERCE') default 'MANUAL'             not null comment '등록 경로 (직접 등록/커머스 자동 입고)',
    created_at      datetime(6)                 default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at      datetime(6)                 default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    product_id      bigint                                                   null,
    constraint fk_fridge_ingredient
        foreign key (ingredient_id) references ingredients (id),
    constraint fk_fridge_member
        foreign key (member_id) references members (id),
    constraint fk_fridge_order_item
        foreign key (order_item_id) references order_items (id)
)
    comment '냉장고 보관 재료 (현재 보관 중인 재료만 저장)';

create index idx_fridge_expiration_date_member_id
    on fridge (expiration_date, member_id);

create index idx_fridge_member_id_expiration_date
    on fridge (member_id, expiration_date);

create table fridge_commerce_histories
(
    id            bigint auto_increment comment '커머스 입고 이력 ID'
        primary key,
    member_id     bigint                                   not null comment '회원 ID',
    order_item_id bigint                                   not null comment '주문 상품 ID (구매 확정된 주문 상품)',
    created_at    datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시 (구매 확정 이벤트 수신 시각)',
    updated_at    datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_fridge_commerce_histories_order_item_id
        unique (order_item_id),
    constraint fk_fridge_commerce_histories_member
        foreign key (member_id) references members (id),
    constraint fk_fridge_commerce_histories_order_item
        foreign key (order_item_id) references order_items (id)
)
    comment '커머스 구매 확정에 따른 냉장고 자동 입고 이력 (중복 입고 방지)';

create table refund_items
(
    id            bigint auto_increment comment '환불 상품 ID'
        primary key,
    refund_id     bigint                                   not null comment '환불 ID',
    order_item_id bigint                                   not null comment '주문 상품 ID',
    quantity      int         default 0                    not null comment '환불 수량',
    unit_price    int         default 0                    not null comment '주문 당시 단가 (주문 상품 스냅샷)',
    amount        bigint      default 0                    not null comment '환불 금액 (단가 × 수량)',
    created_at    datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성 일시',
    updated_at    datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정 일시',
    constraint uk_refund_items_refund_id_order_item_id
        unique (refund_id, order_item_id),
    constraint fk_refund_items_order_item
        foreign key (order_item_id) references order_items (id),
    constraint fk_refund_items_refund
        foreign key (refund_id) references refunds (id)
)
    comment '환불 상품';

create index idx_refund_items_order_item_id
    on refund_items (order_item_id);

create index idx_sale_event_items_product_id
    on sale_event_items (product_id);

create index idx_sale_events_status_ends_at
    on sale_events (status, ends_at);

create index idx_sale_events_status_starts_at
    on sale_events (status, starts_at);

create table sales_forecasts
(
    id                bigint auto_increment comment '상품별 예측 ID'
        primary key,
    prediction_run_id bigint                                   not null comment '예측 실행 ID',
    product_id        bigint                                   not null comment '상품 ID(상품 도메인, 외래키 없음)',
    product_name      varchar(100)                             not null,
    predicted_rank    int                                      null comment '예상 순위(예상 TOP 10 밖이었다가 실제 진입한 상품은 NULL)',
    predicted_qty     int                                      null comment '예상 판매 수량',
    baseline_qty      int         default 0                    not null comment '기준선 예측(전주 판매량)',
    actual_rank       int                                      null comment '실제 순위(확정 후 입력)',
    actual_qty        int                                      null comment '실제 판매 수량(취소·환불 제외, 확정 후 입력)',
    created_at        datetime(6) default CURRENT_TIMESTAMP(6) not null comment '생성일시',
    updated_at        datetime(6) default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시',
    constraint uk_sales_forecasts_run_product
        unique (prediction_run_id, product_id),
    constraint fk_sales_forecasts_prediction_run
        foreign key (prediction_run_id) references prediction_runs (id)
)
    comment '상품별 판매 예측과 실제 판매량';

create table search_click_histories
(
    id         bigint auto_increment
        primary key,
    created_at datetime(6)  not null,
    updated_at datetime(6)  null,
    keyword    varchar(100) not null,
    member_id  bigint       null,
    product_id bigint       not null
);

create index idx_search_click_histories_created_at_product_id
    on search_click_histories (created_at, product_id);

create table search_recipe_click_histories
(
    id         bigint auto_increment
        primary key,
    created_at datetime(6)  not null,
    updated_at datetime(6)  null,
    keyword    varchar(100) not null,
    member_id  bigint       null,
    recipe_id  bigint       not null
);

create index idx_search_recipe_click_histories_created_at_recipe_id
    on search_recipe_click_histories (created_at, recipe_id);

create table search_zero_result_histories
(
    id         bigint auto_increment
        primary key,
    created_at datetime(6)                not null,
    updated_at datetime(6)                null,
    keyword    varchar(50)                not null,
    target     enum ('PRODUCT', 'RECIPE') not null
);

create index idx_search_zero_result_histories_created_at
    on search_zero_result_histories (created_at);

create table webhook_events
(
    id             bigint auto_increment comment '웹훅 이벤트 ID'
        primary key,
    payment_id     bigint                                              null comment '결제 ID (위변조·매칭 실패 시 NULL)',
    webhook_id     varchar(200)                                        not null comment '포트원 웹훅 ID (중복 수신 차단)',
    event_type     varchar(50)                                         not null comment '포트원 이벤트 종류 (예: Transaction.Paid)',
    process_status enum ('FAILED', 'IGNORED', 'PROCESSED', 'RECEIVED') not null,
    raw_payload    text                                                not null comment '수신한 원문',
    fail_reason    varchar(500)                                        null comment '처리 실패 사유',
    processed_at   datetime(6)                                         null comment '처리 완료 시각',
    created_at     datetime(6) default CURRENT_TIMESTAMP(6)            not null comment '생성 일시 (수신 시각)',
    updated_at     datetime(6) default CURRENT_TIMESTAMP(6)            not null on update CURRENT_TIMESTAMP(6) comment '수정 일시',
    constraint uk_webhook_events_webhook_id
        unique (webhook_id),
    constraint fk_webhook_events_payment
        foreign key (payment_id) references payments (id)
)
    comment '포트원 웹훅 수신 이력';

create index idx_webhook_events_payment_id
    on webhook_events (payment_id);

create index idx_webhook_events_process_status
    on webhook_events (process_status, created_at);

-- 구매 확정 이벤트 outbox (구매 확정과 같은 트랜잭션에서 저장, OrderOutboxRelayScheduler가 Kafka로 발행)
create table order_outbox_events
(
    id            bigint auto_increment comment 'outbox 이벤트 ID (클수록 나중에 저장)'
        primary key,
    topic         varchar(100)                                                    not null comment '보낼 Kafka 토픽 (예: purchase-confirmed)',
    message_key   varchar(100)                                                    not null comment 'Kafka 메시지 키 (주문 ID)',
    payload       json                                                            not null comment '이벤트 내용 (발행 때 원래 이벤트 형태로 되돌려 보냄)',
    status        enum ('PENDING', 'PUBLISHED', 'FAILED') default 'PENDING'       not null comment '발행 상태 (대기/완료/실패. 실패는 시도 상한을 넘어 따로 확인할 건)',
    attempt_count int                                     default 0               not null comment '이벤트 자체 문제로 발행에 실패한 횟수 (Kafka 연결 실패는 세지 않음, 상한에 닿으면 FAILED)',
    published_at  datetime(6)                                                     null comment 'Kafka 수신 확인 시각 (완료 전에는 NULL)',
    created_at    datetime(6)                             default CURRENT_TIMESTAMP(6) not null comment '생성일시 (구매 확정과 같은 트랜잭션에서 저장한 시각)',
    updated_at    datetime(6)                             default CURRENT_TIMESTAMP(6) not null on update CURRENT_TIMESTAMP(6) comment '수정일시'
)
    comment '구매 확정 이벤트 outbox (주문 변경과 같은 트랜잭션에서 저장, 스케줄러가 발행)';

create index idx_order_outbox_events_status_id
    on order_outbox_events (status, id);
