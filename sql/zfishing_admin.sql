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
