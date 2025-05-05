//package com.m20891.entity;
//
//import lombok.Getter;
//import lombok.RequiredArgsConstructor;
//import lombok.Setter;
//import lombok.ToString;
//import org.hibernate.Hibernate;
//import org.hibernate.annotations.CreationTimestamp;
//
//import javax.persistence.*;
//import java.util.Date;
//import java.util.Objects;
//
//@Getter
//@Setter
//@ToString
//@RequiredArgsConstructor
//@Table
//@Entity
//public class URLHistory
//{
//    @Id
//    @GeneratedValue(strategy = GenerationType.IDENTITY)
//    private Integer id;
//    private String url;
//    @CreationTimestamp
//    private Date date;
//
//    @Override
//    public boolean equals(Object o)
//    {
//        if (this == o) return true;
//        if (o == null || Hibernate.getClass(this) != Hibernate.getClass(o)) return false;
//        URLHistory that = (URLHistory) o;
//        return getId() != null && Objects.equals(getId(), that.getId());
//    }
//
//    @Override
//    public int hashCode()
//    {
//        return getClass().hashCode();
//    }
//}
