--
-- PostgreSQL database dump
--

-- Dumped from database version 14.8
-- Dumped by pg_dump version 14.8

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: availability_report(date, date, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.availability_report(start_date date, end_date date, node_id integer[]) RETURNS TABLE(date date, unavailable_nodes integer[], availability_percentage double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
    RETURN QUERY
    WITH basedata AS (
	    SELECT DISTINCT t."CreatedTime"::date AS tl, t."NodeId" as node_id, s."Name"  as state 
		from "NodeStatusHistory" t  join "Status" s on t."StatusId" = s."StatusId" 
		where "NodeId" = ANY($3)
		and t."CreatedTime"::date between $1 and $2
	    ),
	    date_series AS (
    		SELECT generate_series($1, $2, '1 day'::interval)::date AS generated_date
		),
	    total_available_units AS (
			select tl,count(distinct nid) units_available from (
				select * from ( 
					select tl ,bd.node_id as nid ,state, count(1) over (partition by tl, bd.node_id) cnt from basedata bd
					) a
				where state not in ('ERROR','ON_HOLD','MAINTENANCE')  and cnt <=10 -- 
			) b
			group by tl
		),
	    unavailable_nodes AS (
	        SELECT tl,
			-- ARRAY_AGG(DISTINCT b."NodeIdentifier") AS unavailable_nodes
			 ARRAY_AGG(DISTINCT b."NodeId") AS unavailable_nodes
	         FROM basedata a join "Node" b on a.node_id =b."NodeId"
	         WHERE  state in ('ERROR','ON_HOLD','MAINTENANCE') 
	        GROUP BY tl
	    )
    SELECT ds.generated_date AS date,
           COALESCE(un.unavailable_nodes, '{}') AS unavailable_nodes,
           coalesce(((cardinality($3) - array_length(un.unavailable_nodes, 1))::FLOAT / cardinality($3) * 100),100) AS availability_percentage
    FROM date_series ds
    LEFT JOIN total_available_units ta ON ds.generated_date = ta.tl
    LEFT JOIN unavailable_nodes un ON ds.generated_date = un.tl;

END;
$_$;


--
-- Name: availabilty_percentage(date, date, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.availabilty_percentage(start_date date, end_date date, node_id integer[]) RETURNS TABLE(date date, unavailable_nodes integer[], availability_percentage double precision)
    LANGUAGE plpgsql
    AS $_$
BEGIN
    RETURN QUERY
    WITH basedata AS (
        SELECT DISTINCT t."CreatedTime"::date AS tl, t."NodeId" as node_id, s."Name" as state
        FROM "NodeStatusHistory" t
        JOIN "Status" s ON t."StatusId" = s."StatusId"
        WHERE "NodeId" = ANY($3)
        AND t."CreatedTime"::date BETWEEN $1 AND $2
    ),
    date_series AS (
        SELECT generate_series($1, $2, '1 day'::interval)::date AS generated_date
    ),
    total_available_units AS (
        SELECT count(1)/2 units_available FROM (
            SELECT * FROM (
                SELECT tl, bd.node_id, state, count(1) OVER (PARTITION BY tl, bd.node_id) cnt
                FROM basedata bd
            ) a
            WHERE state NOT IN ('ERROR', 'ON_HOLD', 'MAINTENANCE') AND cnt <= 10
        ) b
    ),
    unavailable_nodes AS (
        SELECT
            ARRAY_AGG(DISTINCT b."NodeId") AS unavailable_nodes
        FROM basedata a
        JOIN "Node" b ON a.node_id = b."NodeId"
        WHERE state IN ('ERROR', 'ON_HOLD', 'MAINTENANCE')
    )
    SELECT
        coalesce(((cardinality($3) - array_length(un.unavailable_nodes, 1))::FLOAT / cardinality($3) * 100), 100) AS availability_percentage
    FROM date_series ds
    LEFT JOIN total_available_units ta ON ds.generated_date = ta.tl
    LEFT JOIN unavailable_nodes un ON ds.generated_date = un.tl;
END;
$_$;


--
-- Name: calculate_throughput_report(date, date, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calculate_throughput_report(start_date date, end_date date, node_id integer[]) RETURNS TABLE(date_ date, node integer, throughput_percentage double precision)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH total_count AS (
        SELECT 
            request_time::date AS request_date,
            "NodeId",
            COUNT(*) AS total_count,
            AVG(time_difference_seconds) AS avg_time_difference_seconds
        FROM 
            (
                SELECT 
                    r."CreatedOn" AS request_time, 
                    n."NodeId", 
                    s."CreatedTime" AS response_time,
                    EXTRACT(EPOCH FROM (s."CreatedTime" - r."CreatedOn")) AS time_difference_seconds
                FROM 
                    "Response" s
                LEFT JOIN 
                    "Request" r ON r."RequestId" = s."RequestId"
                LEFT JOIN 
                    "Node" n ON r."NodeIdentifier" = n."NodeIdentifier"
                WHERE 
                    r."CreatedOn"::date BETWEEN start_date AND end_date
                    AND n."IsDeleted" = FALSE
                    AND n."NodeId" = ANY (node_id)
            ) AS subquery
        GROUP BY 
            request_date, "NodeId"
    ),
    transactions_within_146s AS (
        SELECT 
            request_time::date AS request_date,
            "NodeId",
            COUNT(*) AS count_within_146s,
            AVG(time_difference_seconds) AS avg_time_difference_seconds
        FROM 
            (
                SELECT 
                    r."CreatedOn" AS request_time, 
                    n."NodeId", 
                    s."CreatedTime" AS response_time,
                    EXTRACT(EPOCH FROM (s."CreatedTime" - r."CreatedOn")) AS time_difference_seconds
                FROM 
                    "Response" s
                LEFT JOIN 
                    "Request" r ON r."RequestId" = s."RequestId"
                LEFT JOIN 
                    "Node" n ON r."NodeIdentifier" = n."NodeIdentifier"
                WHERE 
                    r."CreatedOn"::date BETWEEN start_date AND end_date
                    AND n."IsDeleted" = FALSE
                    AND n."NodeId" = ANY (node_id)
            ) AS subquery
        WHERE 
            time_difference_seconds < 146
        GROUP BY 
            request_date, "NodeId"
    )
    SELECT 
        tc.request_date AS date_, 
        tc."NodeId" AS node, 
        (tw.count_within_146s::FLOAT / tc.total_count) * 100 AS throughput_percentage
    FROM 
        total_count tc
    JOIN 
        transactions_within_146s tw ON tc.request_date = tw.request_date AND tc."NodeId" = tw."NodeId";
END;
$$;


--
-- Name: graphdropdown(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.graphdropdown(startdate date, enddate date) RETURNS TABLE(time_ date, active_count_ bigint, error_count_ bigint, onhold_count_ bigint, inactive_count_ bigint)
    LANGUAGE plpgsql
    AS $_$
BEGIN
RETURN QUERY     
with basedata as (
	select distinct "CreatedTime"::date tl , "NodeId" as name ,s."Name" as state from "NodeStatusHistory" t
	join "Status" s on t."StatusId" = s."StatusId"
	where t."CreatedTime"::date between $1 and $2
	),
	active as (
		select tl,count(1) active_count from (
			select * from ( 
				select tl ,name ,state, count(1) over (partition by tl,name) cnt from basedata
				) a
			where state='ACTIVE' and cnt=1
		) b
		group by tl
	),
	error as (
		select tl,count(1) error_count from (
			select tl ,name ,state, count(1) over (partition by tl,name) cnt from basedata
			where state='ERROR'
			) a
		group by tl		
	),
	onhold as (
		select tl,count(1) onhold_count from (
			select tl ,name ,state, count(1) over (partition by tl,name) cnt from basedata
			where state='ON_HOLD'
			) a
		group by tl		
	),
	inactive as (
		select tl,count(1) inactive_count from (
			select tl ,name ,state, count(1) over (partition by tl,name) cnt from basedata
			where state='INACTIVE'
			) a
		group by tl		
	)
	select a.tl::date time_ ,active_count , coalesce(error_count,0) error_count  ,
	coalesce(onhold_count,0) onhold_count ,  coalesce(inactive_count,0) inactive_count 
    from active a 
    	left join error b on a.tl=b.tl 
    	left join onhold c on a.tl=c.tl
    	left join inactive d on a.tl=d.tl;
			
    
		
		
	END;
$_$;


--
-- Name: mean_avg_transaction_time_report(date, date, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.mean_avg_transaction_time_report(startdate date, enddate date, node_id integer[]) RETURNS TABLE(time_ date, node_ integer, uuid character varying, mean_avg_time numeric, mean_avg_time_percentage numeric)
    LANGUAGE plpgsql
    AS $_$
BEGIN
    RETURN QUERY
    WITH mean_avg_times AS (
        SELECT
            r."CreatedOn"::date AS time_,
            n."NodeId" AS node_,
            r."TrackingId" as uuid,
            SUM(EXTRACT(epoch FROM (s."CreatedTime"::timestamp - r."CreatedOn"::timestamp))) AS mean_avg_time
        FROM
            "Request" r
        LEFT JOIN
            "Response" s ON r."RequestId" = s."RequestId" AND s."CreatedTime"::date BETWEEN $1 AND $2
       left join "Node" n on r."NodeIdentifier" = n."NodeIdentifier" 
        WHERE
            r."CreatedOn"::date BETWEEN $1 AND $2
            and n."NodeId" = ANY ($3)
        GROUP BY
            r."CreatedOn"::date,
            n."NodeId",
            r."TrackingId"
    )
    SELECT
        mt.time_,
        mt.node_,
        mt.uuid,
        coalesce(trunc(mt.mean_avg_time), 0),
        coalesce(trunc(((146.0 / mt.mean_avg_time) * 100)),0) AS mean_avg_time_percentage
    FROM
        mean_avg_times mt;
END;
$_$;


--
-- Name: requestresponse(date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.requestresponse(startdate date, enddate date) RETURNS TABLE(time_ date, requests_sent bigint, response_received bigint, avg_response_time numeric)
    LANGUAGE plpgsql
    AS $_$
BEGIN
RETURN QUERY
WITH request_ AS (
        SELECT r."RequestId" rid, "CreatedOn"::timestamp FROM "Request" r
        WHERE r."CreatedOn"::date BETWEEN $1 AND $2
        ),
        response_ AS (
        SELECT r."RequestId" rid, "CreatedTime"::timestamp FROM "Response" r
        WHERE r."CreatedTime"::date BETWEEN $1 AND $2
        ),
        request_count AS (
        SELECT r."CreatedOn"::date time_, COUNT(1) requests_sent_ FROM request_ r
        GROUP BY r."CreatedOn"::date
        ),
        response_count AS (
        SELECT "CreatedTime"::date time_, COUNT(1) response_recieved_ FROM response_
        GROUP BY "CreatedTime"::date
        ),
        avg_response_time AS (
        SELECT a."CreatedOn"::date time_,
        AVG(EXTRACT(epoch FROM(b."CreatedTime"::timestamp - a."CreatedOn"::timestamp))) avg_response_time_
        FROM request_ a, response_ b
        WHERE a.rid = b.rid
        GROUP BY a."CreatedOn"::date
        )
        SELECT a.time_, a.requests_sent_, b.response_recieved_, trunc(c.avg_response_time_)
        FROM request_count a, response_count b, avg_response_time c
        WHERE a.time_ = b.time_
        AND a.time_ = c.time_
     ;
END;
$_$;


--
-- Name: sum_of_all(date, date, integer[]); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sum_of_all(start_date date, end_date date, node_id integer[]) RETURNS TABLE(total_throughput_percentage double precision, total_mean_avg_time_percentage double precision, total_availability_percentage double precision)
    LANGUAGE plpgsql
    AS $$
DECLARE
    total_throughput_percentage_val double precision := 0;
    total_mean_avg_time_percentage_val double precision := 0;
    total_availability_percentage_val double precision := 0;
BEGIN
    -- Calculate total throughput percentage
  
	SELECT coalesce(AVG(availability_percentage),0) INTO total_availability_percentage_val FROM public.availability_report(start_date, end_date, node_id);
	SELECT coalesce(AVG(throughput_percentage),0) into total_throughput_percentage_val FROM public.calculate_throughput_report(start_date, end_date, node_id);
	SELECT coalesce((146/AVG(mean_avg_time))*100,0) into total_mean_avg_time_percentage_val FROM public.mean_avg_transaction_time_report(start_date, end_date, node_id);
	RETURN QUERY SELECT trunc(total_throughput_percentage_val), trunc(total_mean_avg_time_percentage_val), trunc(total_availability_percentage_val);
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: AlertMessage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."AlertMessage" (
    "AlertMessageId" smallint NOT NULL,
    "NodeId" integer NOT NULL,
    "Code" character varying(255),
    "Message" character varying(255),
    "MessageDate" timestamp without time zone NOT NULL,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp without time zone,
    "LastUpdatedTime" timestamp without time zone
);


--
-- Name: AlertMessage_AlertMessageId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."AlertMessage" ALTER COLUMN "AlertMessageId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."AlertMessage_AlertMessageId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Dut; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Dut" (
    "DutId" integer NOT NULL,
    "ModelNumber" character varying(20),
    "Name" character varying(20),
    "Type" character varying(20),
    "StatusId" smallint,
    "IsDeleted" smallint,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp without time zone,
    "LastUpdatedTime" timestamp without time zone,
    "Model" character varying(250),
    "Make" character varying(250)
);


--
-- Name: Dut_DutId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Dut" ALTER COLUMN "DutId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Dut_DutId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Location; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Location" (
    "LocationId" smallint NOT NULL,
    "Name" character varying(50)
);


--
-- Name: Location_LocationId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Location" ALTER COLUMN "LocationId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Location_LocationId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Node; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Node" (
    "NodeId" integer NOT NULL,
    "Name" character varying(100),
    "SerialNumber" character varying(20),
    "StatusId" smallint,
    "MacAddress" character varying(20),
    "IpAddress" character varying(15),
    "TemplateId" integer,
    "LocationId" smallint,
    "Comment" character varying(500),
    "IsDeleted" boolean,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone,
    "FirmwareVersion" character varying(250),
    "NodeIdentifier" character varying(250),
    "TotalUpTime" character varying(50),
    "TemplateName" character varying(50)
);


--
-- Name: NodeDutMapping; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."NodeDutMapping" (
    "NodeDutMappingId" integer NOT NULL,
    "NodeId" integer,
    "DutId" integer,
    "IsDeleted" smallint,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone
);


--
-- Name: NodeDutMapping_NodeDutMappingId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."NodeDutMapping" ALTER COLUMN "NodeDutMappingId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."NodeDutMapping_NodeDutMappingId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: NodeStatus; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."NodeStatus" (
    "NodeStatusId" integer NOT NULL,
    "NodeId" integer,
    "StatusId" smallint,
    "StatusMessage" character varying(2000),
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone
);


--
-- Name: NodeStatusHistory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."NodeStatusHistory" (
    "NodeStatusHistoryId" integer NOT NULL,
    "NodeId" integer,
    "StatusId" smallint,
    "StatusChangedOn" timestamp with time zone,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone
);


--
-- Name: NodeStatusHistory_NodeStatusHistoryId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."NodeStatusHistory" ALTER COLUMN "NodeStatusHistoryId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."NodeStatusHistory_NodeStatusHistoryId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: NodeStatus_NodeStatusId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."NodeStatus" ALTER COLUMN "NodeStatusId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."NodeStatus_NodeStatusId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Node_NodeId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Node" ALTER COLUMN "NodeId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Node_NodeId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Request; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Request" (
    "RequestId" integer NOT NULL,
    "CreatedOn" timestamp with time zone,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone,
    "Action" character varying(250),
    "TrackingId" character varying(250),
    "NodeIdentifier" character varying(255),
    "DutName" character varying(255),
    "MessageContent" text,
    "IsCompleted" smallint DEFAULT 0
);


--
-- Name: Request_RequestId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Request" ALTER COLUMN "RequestId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Request_RequestId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Response; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Response" (
    "ResponseId" integer NOT NULL,
    "RequestId" integer,
    "ResponseMessage" text,
    "ImagePath" character varying(500),
    "ErrorMessage" character varying(500),
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone,
    "TrackingId" character varying(250)
);


--
-- Name: Response_ResponseId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Response" ALTER COLUMN "ResponseId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Response_ResponseId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Role; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Role" (
    "RoleId" smallint NOT NULL,
    "Name" character varying(50) NOT NULL
);


--
-- Name: Role_RoleId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Role" ALTER COLUMN "RoleId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Role_RoleId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."Status" (
    "StatusId" smallint NOT NULL,
    "Name" character varying(50)
);


--
-- Name: Status_StatusId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."Status" ALTER COLUMN "StatusId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."Status_StatusId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: User; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public."User" (
    "UserId" smallint NOT NULL,
    "UserName" character varying(10),
    "Email" character varying(100),
    "Password" character varying(200),
    "RoleId" smallint,
    "IsActive" boolean,
    "IsDeleted" boolean,
    "PasswordResetRequired" boolean,
    "RetryAttemptCount" smallint,
    "Roles" character varying(250)
);


--
-- Name: User_UserId_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public."User" ALTER COLUMN "UserId" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public."User_UserId_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: nsh1; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nsh1 (
    "NodeStatusHistoryId" integer NOT NULL,
    "NodeId" integer,
    "StatusId" smallint,
    "StatusChangedOn" timestamp with time zone,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone
);


--
-- Name: nsh3; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nsh3 (
    "NodeStatusHistoryId" integer,
    "NodeId" integer,
    "StatusId" smallint,
    "StatusChangedOn" timestamp with time zone,
    "CreatedBy" integer,
    "LastUpdatedBy" integer,
    "CreatedTime" timestamp with time zone,
    "LastUpdatedTime" timestamp with time zone
);


--
-- Name: schemaversions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schemaversions (
    schemaversionid integer NOT NULL,
    scriptname character varying(255) NOT NULL,
    applied timestamp without time zone NOT NULL
);


--
-- Name: schemaversions_schemaversionid_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.schemaversions ALTER COLUMN schemaversionid ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.schemaversions_schemaversionid_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: Dut Dut_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Dut"
    ADD CONSTRAINT "Dut_pkey" PRIMARY KEY ("DutId");


--
-- Name: Location Location_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Location"
    ADD CONSTRAINT "Location_pkey" PRIMARY KEY ("LocationId");


--
-- Name: NodeDutMapping NodeDutMapping_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeDutMapping"
    ADD CONSTRAINT "NodeDutMapping_pkey" PRIMARY KEY ("NodeDutMappingId");


--
-- Name: NodeStatusHistory NodeStatusHistory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeStatusHistory"
    ADD CONSTRAINT "NodeStatusHistory_pkey" PRIMARY KEY ("NodeStatusHistoryId");


--
-- Name: NodeStatus NodeStatus_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeStatus"
    ADD CONSTRAINT "NodeStatus_pkey" PRIMARY KEY ("NodeStatusId");


--
-- Name: Node Node_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Node"
    ADD CONSTRAINT "Node_pkey" PRIMARY KEY ("NodeId");


--
-- Name: Request Request_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Request"
    ADD CONSTRAINT "Request_pkey" PRIMARY KEY ("RequestId");


--
-- Name: Response Response_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Response"
    ADD CONSTRAINT "Response_pkey" PRIMARY KEY ("ResponseId");


--
-- Name: Role Role_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Role"
    ADD CONSTRAINT "Role_pkey" PRIMARY KEY ("RoleId");


--
-- Name: Status Status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Status"
    ADD CONSTRAINT "Status_pkey" PRIMARY KEY ("StatusId");


--
-- Name: User User_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."User"
    ADD CONSTRAINT "User_pkey" PRIMARY KEY ("UserId");


--
-- Name: schemaversions schemaversions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schemaversions
    ADD CONSTRAINT schemaversions_pkey PRIMARY KEY (schemaversionid);


--
-- Name: Dut_StatusId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "Dut_StatusId_idx" ON public."Dut" USING btree ("StatusId");


--
-- Name: NodeDutMapping_DutId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeDutMapping_DutId_idx" ON public."NodeDutMapping" USING btree ("DutId");


--
-- Name: NodeDutMapping_NodeId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeDutMapping_NodeId_idx" ON public."NodeDutMapping" USING btree ("NodeId");


--
-- Name: NodeStatusHistory_CreatTime_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatusHistory_CreatTime_idx1" ON public.nsh3 USING btree ("CreatedTime");


--
-- Name: NodeStatusHistory_NodeId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatusHistory_NodeId_idx" ON public."NodeStatusHistory" USING btree ("NodeId");


--
-- Name: NodeStatusHistory_NodeId_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatusHistory_NodeId_idx1" ON public.nsh3 USING btree ("NodeId");


--
-- Name: NodeStatusHistory_StatusId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatusHistory_StatusId_idx" ON public."NodeStatusHistory" USING btree ("StatusId");


--
-- Name: NodeStatusHistory_StatusId_idx1; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatusHistory_StatusId_idx1" ON public.nsh3 USING btree ("StatusId");


--
-- Name: NodeStatusHistory_pkey1; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX "NodeStatusHistory_pkey1" ON public.nsh3 USING btree ("NodeStatusHistoryId");


--
-- Name: NodeStatus_NodeId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatus_NodeId_idx" ON public."NodeStatus" USING btree ("NodeId");


--
-- Name: NodeStatus_StatusId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "NodeStatus_StatusId_idx" ON public."NodeStatus" USING btree ("StatusId");


--
-- Name: Node_LocationId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "Node_LocationId_idx" ON public."Node" USING btree ("LocationId");


--
-- Name: Node_StatusId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "Node_StatusId_idx" ON public."Node" USING btree ("StatusId");


--
-- Name: Response_RequestId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "Response_RequestId_idx" ON public."Response" USING btree ("RequestId");


--
-- Name: User_RoleId_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX "User_RoleId_idx" ON public."User" USING btree ("RoleId");


--
-- Name: ns_ct_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ns_ct_idx ON public.nsh1 USING btree ("CreatedTime");


--
-- Name: Dut Dut_StatusId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Dut"
    ADD CONSTRAINT "Dut_StatusId_fkey" FOREIGN KEY ("StatusId") REFERENCES public."Status"("StatusId");


--
-- Name: NodeDutMapping NodeDutMapping_DutId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeDutMapping"
    ADD CONSTRAINT "NodeDutMapping_DutId_fkey" FOREIGN KEY ("DutId") REFERENCES public."Dut"("DutId");


--
-- Name: NodeDutMapping NodeDutMapping_NodeId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeDutMapping"
    ADD CONSTRAINT "NodeDutMapping_NodeId_fkey" FOREIGN KEY ("NodeId") REFERENCES public."Node"("NodeId");


--
-- Name: NodeStatusHistory NodeStatusHistory_NodeId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeStatusHistory"
    ADD CONSTRAINT "NodeStatusHistory_NodeId_fkey" FOREIGN KEY ("NodeId") REFERENCES public."Node"("NodeId");


--
-- Name: nsh1 NodeStatusHistory_NodeId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nsh1
    ADD CONSTRAINT "NodeStatusHistory_NodeId_fkey" FOREIGN KEY ("NodeId") REFERENCES public."Node"("NodeId");


--
-- Name: NodeStatusHistory NodeStatusHistory_StatusId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeStatusHistory"
    ADD CONSTRAINT "NodeStatusHistory_StatusId_fkey" FOREIGN KEY ("StatusId") REFERENCES public."Status"("StatusId");


--
-- Name: nsh1 NodeStatusHistory_StatusId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nsh1
    ADD CONSTRAINT "NodeStatusHistory_StatusId_fkey" FOREIGN KEY ("StatusId") REFERENCES public."Status"("StatusId");


--
-- Name: NodeStatus NodeStatus_NodeId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeStatus"
    ADD CONSTRAINT "NodeStatus_NodeId_fkey" FOREIGN KEY ("NodeId") REFERENCES public."Node"("NodeId");


--
-- Name: NodeStatus NodeStatus_StatusId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."NodeStatus"
    ADD CONSTRAINT "NodeStatus_StatusId_fkey" FOREIGN KEY ("StatusId") REFERENCES public."Status"("StatusId");


--
-- Name: Node Node_LocationId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Node"
    ADD CONSTRAINT "Node_LocationId_fkey" FOREIGN KEY ("LocationId") REFERENCES public."Location"("LocationId");


--
-- Name: Node Node_StatusId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."Node"
    ADD CONSTRAINT "Node_StatusId_fkey" FOREIGN KEY ("StatusId") REFERENCES public."Status"("StatusId");


--
-- Name: User User_RoleId_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public."User"
    ADD CONSTRAINT "User_RoleId_fkey" FOREIGN KEY ("RoleId") REFERENCES public."Role"("RoleId");


--
-- PostgreSQL database dump complete
--

