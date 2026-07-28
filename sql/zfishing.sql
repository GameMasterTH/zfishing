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
