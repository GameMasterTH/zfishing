-- Migration: com.zcore.zfishing/001-schema (up)
-- Ordered, forward-only schema creation for zfishing.
-- Applied by the Site Agent as a declarative migration BEFORE the resource
-- starts. The resource itself must never create or alter schema at boot
-- (Site Agent-only DB mutation boundary).
-- Transaction: preferred. Destructive: false. Retention: package-business-data.

CREATE TABLE IF NOT EXISTS `zfishing_players` (
    `identifier` VARCHAR(64) NOT NULL,
    `xp` INT NOT NULL DEFAULT 0,
    `level` INT NOT NULL DEFAULT 1,
    `stats` LONGTEXT DEFAULT NULL,
    `updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`identifier`)
);

CREATE TABLE IF NOT EXISTS `zfishing_catches` (
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `identifier` VARCHAR(64) NOT NULL,
    `species` VARCHAR(32) NOT NULL,
    `weight` DECIMAL(6,2) NOT NULL,
    `quality` TINYINT NOT NULL,
    `zone` VARCHAR(48) DEFAULT NULL,
    `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    INDEX `idx_identifier` (`identifier`),
    INDEX `idx_species` (`species`)
);

CREATE TABLE IF NOT EXISTS `zfishing_settings` (
    `key`   VARCHAR(48) NOT NULL,
    `value` LONGTEXT NOT NULL,
    PRIMARY KEY (`key`)
);

CREATE TABLE IF NOT EXISTS `zfishing_zones` (
    `id`      INT AUTO_INCREMENT PRIMARY KEY,
    `name`    VARCHAR(64) NOT NULL,
    `water`   VARCHAR(16) NOT NULL,
    `x`       DOUBLE NOT NULL,
    `y`       DOUBLE NOT NULL,
    `z`       DOUBLE NOT NULL,
    `radius`  DOUBLE NOT NULL,
    `pool`    LONGTEXT DEFAULT NULL,
    `enabled` TINYINT NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS `zfishing_fish` (
    `species` VARCHAR(32) NOT NULL,
    `data`    LONGTEXT NOT NULL,
    PRIMARY KEY (`species`)
);

CREATE TABLE IF NOT EXISTS `zfishing_equipment` (
    `slot` VARCHAR(16) NOT NULL,
    `item` VARCHAR(48) NOT NULL,
    `data` LONGTEXT NOT NULL,
    PRIMARY KEY (`slot`, `item`)
);
