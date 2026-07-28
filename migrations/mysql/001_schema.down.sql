-- Migration: com.zcore.zfishing/001-schema (down)
-- Reverse of 001_schema.up.sql. Dropped in reverse creation order.
-- Destructive at rollback time: the Site Agent requires a verified Recovery_Point
-- and policy-authorized approval before applying this (data-retention =
-- package-business-data). The resource never runs this itself.

DROP TABLE IF EXISTS `zfishing_equipment`;
DROP TABLE IF EXISTS `zfishing_fish`;
DROP TABLE IF EXISTS `zfishing_zones`;
DROP TABLE IF EXISTS `zfishing_settings`;
DROP TABLE IF EXISTS `zfishing_catches`;
DROP TABLE IF EXISTS `zfishing_players`;
