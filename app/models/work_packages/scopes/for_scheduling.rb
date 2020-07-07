#-- encoding: UTF-8

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2020 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2017 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See docs/COPYRIGHT.rdoc for more details.
#++
#

module WorkPackages::Scopes
  class ForScheduling
    class << self
      def fetch(work_packages)
        # TODO: try to get rid of this
        return [] if work_packages.empty?

        sql = <<~SQL
          WITH
            #{paths_sql(work_packages)},
            #{manual_in_path_sql},
            #{manual_by_hierarchy_sql},
            #{manual_by_path_sql},
            #{leafs_in_path_sql},
            #{automatic_in_hierarchy_and_path_sql},
            #{automatic_without_broken_paths_sql}

          SELECT DISTINCT work_packages.*
          FROM automatic_without_broken_paths
          JOIN work_packages ON work_packages.id = automatic_without_broken_paths.id
          AND work_packages.id NOT IN (#{work_packages.map(&:id).join(',')})
        SQL

        WorkPackage.find_by_sql(sql)
      end

      private

      def paths_sql(work_packages)
        values = work_packages.map { |wp| "(#{wp.id},#{wp.id},ARRAY[#{wp.id}])" }.join(', ')

        <<~SQL
          RECURSIVE paths(from_id, last_joined_id, path) AS (
            SELECT * FROM (VALUES#{values}) AS t(from_id, last_joined_id, path)

            UNION ALL

            SELECT
              CASE
                WHEN relations.to_id = paths.from_id
                THEN relations.from_id
                ELSE relations.to_id
              END from_id,
              CASE
                WHEN relations.to_id = paths.from_id
                THEN relations.to_id
                ELSE relations.from_id
              END last_joined_id,
              CASE
                WHEN relations.to_id = paths.from_id
                THEN array_append(path, relations.from_id)
                ELSE array_append(path, relations.to_id)
              END final_path
            FROM
              paths
            JOIN
              relations
              ON (relations.to_id = paths.from_id AND relations.from_id != paths.last_joined_id AND "relations"."relates" = 0 AND "relations"."duplicates" = 0 AND "relations"."blocks" = 0 AND "relations"."includes" = 0 AND "relations"."requires" = 0
                AND (relations.hierarchy + relations.relates + relations.duplicates + relations.follows + relations.blocks + relations.includes + relations.requires = 1))
              OR (relations.from_id = paths.from_id AND relations.to_id != paths.last_joined_id AND "relations"."follows" = 0 AND "relations"."relates" = 0 AND "relations"."duplicates" = 0 AND "relations"."blocks" = 0 AND "relations"."includes" = 0 AND "relations"."requires" = 0
                AND (relations.hierarchy + relations.relates + relations.duplicates + relations.follows + relations.blocks + relations.includes + relations.requires = 1))
          )
        SQL
      end

      def manual_in_path_sql
        <<~SQL
          manually AS (
            SELECT from_id from paths
            JOIN work_packages ON work_packages.id = paths.from_id
            WHERE work_packages.schedule_manually = true
          )
        SQL
      end

      def manual_by_hierarchy_sql
        <<~SQL
          manual_by_hierarchy AS (
            SELECT
              relations.from_id
            FROM
              manually
            LEFT JOIN relations
              ON manually.from_id = relations.to_id AND  "relations"."follows" = 0 AND "relations"."relates" = 0 AND "relations"."duplicates" = 0 AND "relations"."blocks" = 0 AND "relations"."includes" = 0 AND "relations"."requires" = 0
              AND (relations.hierarchy + relations.relates + relations.duplicates + relations.follows + relations.blocks + relations.includes + relations.requires != 0)
            WHERE relations.from_id IS NOT NULL
          )
        SQL
      end

      def manual_by_path_sql
        <<~SQL
          manual_by_path AS (
            SELECT
              paths.from_id, manually.from_id manual_id
            FROM
              paths
            JOIN manually
            ON manually.from_id = any(paths.path)
          )
        SQL
      end

      def leafs_in_path_sql
        <<~SQL
          leafs_in_path AS (
            SELECT paths.from_id id
            FROM paths
            LEFT JOIN
            relations
            ON paths.from_id = relations.from_id AND "relations".hierarchy = 1 AND "relations"."follows" = 0 AND "relations"."relates" = 0 AND "relations"."duplicates" = 0 AND "relations"."blocks" = 0 AND "relations"."includes" = 0 AND "relations"."requires" = 0
            AND (relations.hierarchy + relations.relates + relations.duplicates + relations.follows + relations.blocks + relations.includes + relations.requires = 1)
            WHERE relations.from_id IS NULL
          )
        SQL
      end

      def automatic_in_hierarchy_and_path_sql
        <<~SQL
          automatic_in_hierarchy_and_path AS (
            SELECT
              paths.from_id id,
              paths.path,
              manual_by_path.manual_id
            FROM
            paths
            LEFT JOIN relations
            ON paths.from_id = relations.from_id AND relations.to_id IN (SELECT id FROM leafs_in_path) AND "relations"."follows" = 0 AND "relations"."relates" = 0 AND "relations"."duplicates" = 0 AND "relations"."blocks" = 0 AND "relations"."includes" = 0 AND "relations"."requires" = 0
            AND (relations.hierarchy + relations.relates + relations.duplicates + relations.follows + relations.blocks + relations.includes + relations.requires != 0)
            LEFT JOIN manual_by_path
            ON manual_by_path.from_id = relations.to_id OR (manual_by_path.from_id = paths.from_id AND manual_by_path.manual_id IS NOT NULL)
          )
        SQL
      end

      #  Removes all paths that are broken in the sense that one node of them is no longer in the set of automatically
      #  scheduled work nodes.
      #  That can happen when they are removed by the manually scheduling being promoted up the hierarchy.
      def automatic_without_broken_paths_sql
        <<~SQL
          automatic_without_broken_paths AS (
            SELECT *
            FROM automatic_in_hierarchy_and_path
            WHERE path <@ (SELECT array_agg(id) FROM automatic_in_hierarchy_and_path WHERE manual_id IS NULL)
          )
        SQL
      end
    end
  end
end
